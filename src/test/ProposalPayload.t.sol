// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.4.22 <0.9.0;
pragma abicoder v2;

// testing libraries
import "ds-test/test.sol";
import "forge-std/console.sol";
import {stdCheats} from "forge-std/stdlib.sol";

// contract dependencies
import "../interfaces/IAaveGovernanceV2.sol";
import "../interfaces/IExecutorWithTimelock.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IProtocolDataProvider.sol";

import "../ProposalPayload.sol";

interface Vm {
    // Set block.timestamp (newTimestamp)
    function warp(uint256) external;

    function roll(uint256) external;

    function expectEmit(
        bool,
        bool,
        bool,
        bool
    ) external;

    function prank(address) external;

    function expectRevert(bytes calldata) external;

    function startPrank(address) external;

    function stopPrank() external;
}

contract ProposalPayloadTest is DSTest, stdCheats {
    Vm vm = Vm(HEVM_ADDRESS);

    address aaveTokenAddress = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    IERC20 aaveToken = IERC20(aaveTokenAddress);

    address aaveGovernanceAddress = 0xEC568fffba86c094cf06b22134B23074DFE2252c;
    address aaveGovernanceShortExecutor = 0xEE56e2B3D491590B5b31738cC34d5232F378a8D5;

    IAaveGovernanceV2 aaveGovernanceV2 = IAaveGovernanceV2(aaveGovernanceAddress);
    IExecutorWithTimelock shortExecutor = IExecutorWithTimelock(aaveGovernanceShortExecutor);

    address[] private aaveWhales;

    address private proposalPayloadAddress;

    address[] private targets;
    uint256[] private values;
    string[] private signatures;
    bytes[] private calldatas;
    bool[] private withDelegatecalls;
    bytes32 private ipfsHash = 0x0;

    uint256 proposalId;

    IERC20 private constant wBtc = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 private constant aWBTC = IERC20(0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656);
    address private constant reserveFactorV2 = 0x464C71f6c2F760DdA6093dCB91C24c39e5d6e18c;

    IProtocolDataProvider private constant dataProvider = IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    address private constant dpi = 0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b;

    function setUp() public {
        // aave whales may need to be updated based on the block being used
        // these are sometimes exchange accounts or whale who move their funds

        // select large holders here: https://etherscan.io/token/0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9#balances
        aaveWhales.push(0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8);
        aaveWhales.push(0x26a78D5b6d7a7acEEDD1e6eE3229b372A624d8b7);
        aaveWhales.push(0x2FAF487A4414Fe77e2327F0bf4AE2a264a776AD2);

        // create proposal is configured to deploy a Payload contract and call execute() as a delegatecall
        // most proposals can use this format - you likely will not have to update this
        _createProposal();

        // these are generic steps for all proposals - no updates required
        _voteOnProposal();
        _skipVotingPeriod();
        _queueProposal();
        _skipQueuePeriod();
    }

    function testProposalExecution() public {
        // get initial state for testing
        uint256 wBTCcollectorBalanceBefore = wBtc.balanceOf(reserveFactorV2);
        uint256 wBTCbalanceOfExecutor = wBtc.balanceOf(aaveGovernanceShortExecutor);

        uint256 aWBTCcollectorBalanceBefore = aWBTC.balanceOf(reserveFactorV2);
        uint256 aWBTCbalanceOfExecutor = aWBTC.balanceOf(aaveGovernanceShortExecutor);

        // execute proposal
        aaveGovernanceV2.execute(proposalId);

        // confirm state after
        IAaveGovernanceV2.ProposalState state = aaveGovernanceV2.getProposalState(proposalId);
        assertEq(uint256(state), uint256(IAaveGovernanceV2.ProposalState.Executed), "PROPOSAL_NOT_IN_EXPECTED_STATE");

        // assertEq(wBtc.balanceOf(aaveGovernanceShortExecutor), wBTCcollectorBalanceBefore + wBTCbalanceOfExecutor);
        // assertEq(aWBTC.balanceOf(aaveGovernanceShortExecutor), aWBTCcollectorBalanceBefore + aWBTCbalanceOfExecutor);

        (,,,,,, bool borrowEnabled, bool stableBorrowEnabled,,) = dataProvider.getReserveConfigurationData(dpi);
        assertTrue(borrowEnabled, "DPI_BORROW_NOT_ENABLED");
        assertTrue(!stableBorrowEnabled, "DPI_STABLE_BORROW_ENABLED");
    }

    /*******************************************************************************/
    /******************     Aave Gov Process - Create Proposal     *****************/
    /*******************************************************************************/

    function _createProposal() public {
        ProposalPayload proposalPayload = new ProposalPayload();
        proposalPayloadAddress = address(proposalPayload);

        bytes memory emptyBytes;

        targets.push(proposalPayloadAddress);
        values.push(0);
        signatures.push("execute()");
        calldatas.push(emptyBytes);
        withDelegatecalls.push(true);

        vm.prank(aaveWhales[0]);
        aaveGovernanceV2.create(shortExecutor, targets, values, signatures, calldatas, withDelegatecalls, ipfsHash);
        proposalId = aaveGovernanceV2.getProposalsCount() - 1;
    }

    /*******************************************************************************/
    /***************     Aave Gov Process - No Updates Required      ***************/
    /*******************************************************************************/

    function _voteOnProposal() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.roll(proposal.startBlock + 1);
        for (uint256 i; i < aaveWhales.length; i++) {
            vm.prank(aaveWhales[i]);
            aaveGovernanceV2.submitVote(proposalId, true);
        }
    }

    function _skipVotingPeriod() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.roll(proposal.endBlock + 1);
    }

    function _queueProposal() public {
        aaveGovernanceV2.queue(proposalId);
    }

    function _skipQueuePeriod() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.warp(proposal.executionTime + 1);
    }

    function testSetup() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        assertEq(proposalPayloadAddress, proposal.targets[0], "TARGET_IS_NOT_PAYLOAD");

        IAaveGovernanceV2.ProposalState state = aaveGovernanceV2.getProposalState(proposalId);
        assertEq(uint256(state), uint256(IAaveGovernanceV2.ProposalState.Queued), "PROPOSAL_NOT_IN_EXPECTED_STATE");
    }
}
