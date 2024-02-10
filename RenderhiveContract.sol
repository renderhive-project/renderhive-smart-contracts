// SPDX-License-Identifier: MIT OR Apache-2.0
// 2023 © Christian Stolze

pragma solidity >= 0.8.9;

import "./node_modules/@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "./node_modules/@openzeppelin/contracts/access/Ownable.sol";
import "./node_modules/@openzeppelin/contracts/utils/Pausable.sol";
import "./node_modules/@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./node_modules/@hashgraph/smart-contracts/contracts/exchange-rate-precompile/SelfFunding.sol";

contract RenderhiveContract is ReentrancyGuard, Pausable, SelfFunding {

// contract RenderhiveContract is ReentrancyGuard, Ownable, Pausable, SelfFunding {

//     constructor(address initialOwner) Ownable(initialOwner) {
//     }

    // TODO: - optimize code for gas costs (e.g., https://medium.com/@novablitz/storing-structs-is-costing-you-gas-774da988895e, https://hacken.io/discover/solidity-gas-optimization/, ...)

    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  CONTRACT CONSTRUCTOR
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // reference time for the hive cycle calculation (in seconds since 1970-01-01)
    uint256 private HIVE_START_TIME;

    // constructor to initialize the contract
    constructor() {
        HIVE_START_TIME = block.timestamp;
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  CONSTANTS & ENUMERATIONS
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // Required amount of USD (in cents) to be deposited by each node to particpate in the network.
    // This so-called safte deposit is used to disincentivize malicious behavior and to cover the 
    // costs of refunds in case of a maliciously behaving node.
    uint256 public constant REQUIRED_SAFETY_DEPOSITY_USD_CENTS = 500;

    // The hive cycle duration in seconds defines the time interval in which the render jobs are distributed
    uint256 public constant HIVE_CYCLE_DURATION = 300 seconds;


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  EVENTS
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // TODO: Implement events for all important the functions (e.g, deposit, withdraw, etc.)

    // operator events
    event RegisteredUser(address indexed operatorAccount, uint256 registrationTime);
    event UnregisteredUser(address indexed operatorAccount, uint256 deletionTime);

    // node events
    event AddedNode(address indexed operatorAccount, address indexed nodeAccount, string topicID, uint256 registrationTime);
    event RemovedNode(address indexed operatorAccount, address indexed nodeAccount, string topicID, uint256 deletionTime);

    // balance events
    event BalanceTransfer(address sendingOperatorAccount, address receivingOperatorAccount, uint256 amount, uint256 time);

    // render job & invoice events
    event AddedRenderJob(string indexed jobCID, address jobOwner, uint256 balance, uint256 estimatedWork, uint256 submissionTime);
    event DepositedRenderJobFunds(string indexed jobCID, address jobOwner, uint256 amount, uint256 submissionTime);
    event ClaimedRenderJob(string indexed jobCID, address jobOwner, uint256 hiveCycle, address claimingNodeAccount, uint8 nodeCount, uint128 nodeShare, bytes32 jobRoot, bytes32 consensusRoot);
    event ArchivedRenderJob(string indexed jobCID, address jobOwner, uint256 archivingTime);
    event ClaimedRenderJobInvoice(string indexed jobCID, address jobOwner, string invoiceCID, uint256 hiveCycle, address invoiceIssuerAccount, uint256 invoicedWork, uint256 invoicedAmount, uint256 paymentTime);





    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  HIVE CYCLE MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    
    // function to calculate the current hive cycle
    // NOTE: This is used mostly internally. But Renderhive nodes may also call it via a mirror node 
    //       or JSON-RPC to determine the current hive cycle directly from the contract.
    function getCurrentHiveCycle() 
        public 
        view

        returns(uint256)
    {
        
        // calculate the hive cycle using a ceil calculation mode
        uint256 diff = block.timestamp - HIVE_START_TIME;
        uint256 result = diff / HIVE_CYCLE_DURATION;
        if (diff % HIVE_CYCLE_DURATION > 0) {
            result += 1;
        }

        return result;

    }
    
    // function to calculate the current hive time (i.e., the time since the deployment of the contract)
    // NOTE: Renderhive nodes may call this to synchronize their local time with the hive time.
    //       This enables the node to calculate the hive cycle on its own.
    function getCurrentHiveTime() 
        external 
        view

        returns(uint256)
    {
        
        // calculate the time passed since the deployment of the contract
        uint256 diff = block.timestamp - HIVE_START_TIME;

        return diff;

    }
    
    // function to get the hive start time
    function getHiveStartTime() 
        external 
        view

        returns(uint256)
    {
        
        // return the hive's start time
        return HIVE_START_TIME;

    }




    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  OPERATOR MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // these functions enable the registration and magegement of operators on the Renderhive network
    struct Operator {

        // operator information
        // bytes64 publicKey;        // the public key of the operator (secp256k1 ECDSA)
        string operatorTopic;        // the address of the operator topic on Hedera
        uint256 balance;             // the amount of HBAR owned by the operator in the smart contract, which can be immediately withdrawn
        uint256 registrationTime;    // the time when the operator registered on the smart contract
        uint256 lastActivity;        // the time when the operator had its last (state changing) activity on the smart contract

        // status flags
        bool isArchived;             // flag to indicate if the operator is active

    }

    // mapping to store operator information via the operator's wallet address
    mapping(address => Operator) private operators;

    // function to register a new operator account
    function registerOperator(string calldata _operatorTopic) 
        external 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling account is already registered as operator
        require(operators[msg.sender].registrationTime == 0, "Calling operator is already registered or was registered before");

        // check if the calling account is not already registered as node
        require(Nodes[msg.sender].registrationTime == 0, "Calling address is already registered as node");

        // create a new operator
        operators[msg.sender] = Operator({
            operatorTopic: _operatorTopic,      // initial operatorTopic
            balance: 0,                         // initial balance
            registrationTime: block.timestamp,  // current block timestamp
            lastActivity: block.timestamp,      // current block timestamp
            isArchived: false                   // initial isArchived
        });

        // emit an event about the registration
        emit RegisteredUser(msg.sender, operators[msg.sender].registrationTime);

    }

    // function to unregister the calling operator account
    // NOTE: Decided against deleting the operator data to make historical data queryable
    function unregisterOperator() 
        external 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // get the operator data
        Operator storage operatorData = operators[msg.sender];

        // TODO: Need to make sure that their is no active task for this operator (e.g., pending render jobs, pending payments, etc.)
        // check if operator has no pending render jobs
        require(operatorRenderJobs[msg.sender].length == 0, "Operator has active render jobs");

        // loop through all the operator's nodes and remove them from the operator account
        address[] storage thisOperatorNodes = operatorNodes[msg.sender];
        for (uint256 i = 0; i < thisOperatorNodes.length; i++) {
            removeNode(thisOperatorNodes[i]);
        }

        // transfer any remaining balance back to the operator account
        if (operatorData.balance > 0) {
            payable(msg.sender).transfer(operatorData.balance);
            operatorData.balance = 0;
        }

        // we keep the operator record in order to keep track of historical data, but we mark it as archived
        operatorData.isArchived = true;

        // emit an event about the deletion
        emit UnregisteredUser(msg.sender, block.timestamp);

        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to check if the given address is a registered operator
    function isOperator(address _operatorAccount) 
        public 
        view 

        returns(bool)
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // check if the given operator is registered as operator and NOT archived
        return (operators[_operatorAccount].registrationTime != 0 && operators[_operatorAccount].isArchived == false);

    }

    // function to deposit the specified amount of HBAR in the operator's balance
    function depositOperatorFunds() 
        external 
        payable
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // make sure a deposit was provided
        require(msg.value > 0, "The amount of HBAR deposited must not be zero");

        // update the operator balance value
        operators[msg.sender].balance += msg.value;
        
        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to withdraw specified amount of TINYBAR from the operator's balance
    function withdrawOperatorFunds(uint256 _amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        
        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if the operator balance is sufficient
        require(_amount > 0, "Amount must be greater than zero");
        require(operators[msg.sender].balance >= _amount, "Insufficient balance");

        // get the operator data
        Operator storage operatorData = operators[msg.sender];
    
        // check if the balance is sufficient taken into consideration the pending render jobs
        require(operatorData.balance >= _amount, "Specified amount can not be withdrawn due to unpaid render jobs");

        // update the operator balance value
        operatorData.balance -= _amount;

        // withdraw the specified amount to the operator account
        payable(msg.sender).transfer(_amount);
        
        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to get the total balance of an operator's nodes stored in the contract (only callable by the operator)
    function getOperatorBalance(address _operatorAccount) 
        public 
        view 
        returns(uint256) 
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // check if the queried account is registered as operator and not archived
        require(operators[_operatorAccount].registrationTime != 0, "Address is not known");
        require(operators[_operatorAccount].isArchived == false, "Address was archived and no more changes or queries are allowed");

        // return the balance
        return operators[_operatorAccount].balance;

    }

    // function to get the reserved amount of the operator funds (i.e., the sum of all render job deposits)
    function getReservedOperatorFunds(address _operatorAccount) 
        public 
        view 
        returns(uint256) 
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // check if the queried account is registered as operator and not archived
        require(operators[_operatorAccount].registrationTime != 0, "Address is not known");
        require(operators[_operatorAccount].isArchived == false, "Address was archived and no more changes or queries are allowed");

        // sum up all deposits of pending render jobs of this operator
        uint256 renderJobCosts = 0;
        for (uint256 i = 0; i < operatorRenderJobs[_operatorAccount].length; i++) {
            if (RenderJobs[operatorRenderJobs[_operatorAccount][i]].owner == _operatorAccount) {
                if (RenderJobs[operatorRenderJobs[_operatorAccount][i]].isArchived == false) {
                    renderJobCosts += RenderJobs[operatorRenderJobs[_operatorAccount][i]].balance;
                }
            }
        }

        // return the accumulated amount of reserved funds (from the render job deposits)
        return renderJobCosts;

    }

    // function to get the last activity (only callable by the operator)
    function getOperatorLastActivity(address _operatorAccount) 
        public 
        view 

        returns(uint256) 
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // check if the queried account is registered as operator and not archived
        require(operators[_operatorAccount].registrationTime != 0, "Address is not known");
        require(operators[_operatorAccount].isArchived == false, "Address was archived and no more changes or queries are allowed");

        // return the balance
        return operators[_operatorAccount].lastActivity;

    }




    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  NODE MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // these functions enable the registration and management of nodes owned by operators on the Renderhive network
    struct Node {

        // node information
        address operatorAccount;
        string nodeTopic;            // the address of the operator topic on Hedera
        uint256 nodeStake;           // the amount of HBAR staked by the node via the smart contract
        uint256 registrationTime;    // the time when the node was registered on the smart contract
        uint256 lastActivity;        // the time when the node had its last (state changing) activity on the smart contract

        // node status flags
        bool isStaked;               // flag to indicate if the node is staked (i.e., has deposited the required node stake)
        bool isArchived;             // flag to indicate if the node was removed (i.e., the node was deactivated and no more changes are allowed)

    }

    // mapping to node data (based on the node's account address)
    mapping(address => Node) private Nodes;

    // mapping to an array of all the nodes owned by a specific operator (based on operator's account address)
    mapping(address => address[]) private operatorNodes;

    // function to add a new node to an operator account
    function addNode(address _nodeAccount, string calldata _nodeTopic) 
        external 
        payable 
        nonReentrant 
        whenNotPaused
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check that the address does not belong to an already registered operator
        require((operators[_nodeAccount].registrationTime == 0), "An operator can not be registered as node");

        // check if the given node account is NOT already registered as node
        require(Nodes[_nodeAccount].registrationTime == 0, "Node with this address is already registered");

        // TODO: Do we need to check if another node with the same nodeTopic is already registered?

        // convert the node stake into HBAR with the help of the exchange rate precompile
        uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
        uint256 requiredTinybars = tinycentsToTinybars(tinycents);

        // check if the required node stake was provided
        require(msg.value >= requiredTinybars, "Insufficient node stake provided");

        // refund the excess amount provided if any
        uint256 excess = msg.value - requiredTinybars;
        if (excess > 0) {
            // refund the excess amount provided for the node stake
            payable(msg.sender).transfer(excess);
        }

        // add the new node to the Nodes mapping
        Nodes[_nodeAccount] = Node({
            operatorAccount: msg.sender,
            nodeTopic: _nodeTopic,
            nodeStake: requiredTinybars,
            registrationTime: block.timestamp,
            lastActivity: block.timestamp,
            isStaked: true,
            isArchived: false
        });

        // add the node account to operatorNodes mapping
        operatorNodes[msg.sender].push(_nodeAccount);

        // emit an event about the added node
        emit AddedNode(msg.sender, _nodeAccount, _nodeTopic, block.timestamp);

        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to remove a node from an operator account
    function removeNode(address _nodeAccount) 
        public 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as this operator's node");

        // Operator's node array
        address[] storage thisOperatorNodes = operatorNodes[msg.sender];

        // find the index of the node in the operatorNodes array
        uint256 index = 0;
        while (thisOperatorNodes[index] != _nodeAccount) {
            index++;
            require(index < thisOperatorNodes.length, "Node not found in operator's node list");
        }

        // if there is a node stake, transfer it to the operator account
        if (Nodes[_nodeAccount].nodeStake > 0) {
            payable(Nodes[_nodeAccount].operatorAccount).transfer(Nodes[_nodeAccount].nodeStake);
        }

        // mark the node as archived
        Nodes[_nodeAccount].isStaked = false;
        Nodes[_nodeAccount].isArchived = true;

        // remove the node from the operatorNodes array
        thisOperatorNodes[index] = thisOperatorNodes[operatorNodes[msg.sender].length - 1];
        thisOperatorNodes.pop();

        // emit an event about the deleted node
        emit RemovedNode(msg.sender, _nodeAccount, Nodes[_nodeAccount].nodeTopic, block.timestamp);

        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to check if the node is a valid node of the given operator account
    function isNode(address _operatorAccount, address _nodeAccount) 
        public 
        view 

        returns(bool)
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // check if the given account is registered as operator
        bool isRegisteredOperator = (operators[_operatorAccount].registrationTime != 0);

        // check if the given node account is registered
        bool isRegisteredNode = (Nodes[_nodeAccount].registrationTime != 0);

        // check if the node data states the correct operator account
        bool isInOperatorNodes = (Nodes[_nodeAccount].operatorAccount == _operatorAccount);

        // have the above checks passed successfully?
        if (isRegisteredOperator && isRegisteredNode && isInOperatorNodes) {

            // get array of operator nodes 
            address[] storage thisOperatorNodes = operatorNodes[_operatorAccount];

            // check if the node is in the array of the operator's nodes
            for (uint256 i = 0; i < thisOperatorNodes.length; i++) {
                if (thisOperatorNodes[i] == _nodeAccount) {
                    return true;
                }
            }

        }

        // otherwise the node is not owned by the operator
        return false;

    }

    // TODO: Implement a locking mechanism for the node stake.

    // function to deposit the node stake for a node from the operator account
    function depositNodeStake(address _nodeAccount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as this operator's node");

        // get the node data
        Node storage nodeData = Nodes[_nodeAccount];

        // convert the required node stake value into HBAR with the help of the exchange rate precompile
        uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
        uint256 requiredTinybars = tinycentsToTinybars(tinycents);

        // check if the node has insufficient stake
        require(nodeData.nodeStake < requiredTinybars, "Node already has sufficient stake");

        // check if the required node stake was provided
        require((nodeData.nodeStake + msg.value) >= requiredTinybars, "Insufficient node stake provided");

        // refund the excess amount provided if any
        uint256 excess = (nodeData.nodeStake + msg.value) - requiredTinybars;
        if (excess > 0) {
            // refund the excess amount provided for the node stake
            payable(msg.sender).transfer(excess);
        }

        // update the node stake value and make it active
        nodeData.nodeStake = requiredTinybars;
        nodeData.isStaked = true;
    
        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to withdraw the node stake of a node to the operator account
    function withdrawNodeStake(address _nodeAccount) 
        external 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as this operator's node");

        // TODO: Implement a locking mechanism for the node stake, so that it can only be withdrawn after a certain time period.

        // TODO: check if the node has any active render jobs

        // get the node data
        Node storage nodeData = Nodes[_nodeAccount];
        uint256 nodeStake = nodeData.nodeStake;

        // check if the node stake is greater than zero
        require(nodeStake > 0, "No node stake to withdraw");

        // update the nodes node stake value and make it inactive
        nodeData.nodeStake = 0;
        nodeData.isStaked = false;

        // withdraw the node stake to the operator account and make the node inactive
        payable(msg.sender).transfer(nodeStake);
    
        // update the calling addresses last activity timestamp
        _updateLastActivity(msg.sender);

    }

    // function to get the current stake of the node
    function getNodeStake(address _nodeAccount) 
        external 
        view 

        returns(uint256)
    {

        // check if the calling address is registered as active operator OR active node
        require(((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) || (Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false)), "Function call is only allowed for registered operators or nodes");

        // return the stake of the given node as result
        return Nodes[_nodeAccount].nodeStake;

    }



    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  RENDER JOB MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // these functions enable the management of render jobs, which are submitted by users and executed by nodes

    // Render job control
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    struct RenderJobClaim {

        // claim information
        address node;           // claiming node
        uint8 nodeCount;        // number of nodes that will render the job according to the consensus
        uint128 nodeShare;      // the estimate for the amount of work the node is intending to deliver (in parts per 10,000 of the total work, i.e. 1% = 100 parts per 10,000)
        bytes32 jobRoot;        // merkle root of the render job for the given hive cycle as claimed by the node
        bytes32 consensusRoot;  // merkle root of the complete job distribution for the given hive cycle as claimed by the node

        // invoice information
        string invoiceCID;      // the CID of the invoice document
        uint256 invoicedAmount; // the amount of HBAR invoiced by the node for the render job and paid by the job owner
        uint256 invoicedTime;   // the amount of HBAR invoiced by the node for the render job and paid by the job owner
        bool invoiceRevoked;    // flag to indicate if the invoice was revoked by the job owner after payment
    }
    struct RenderJob {

        // render job information
        string jobCID;                                  // the CID of the render job request document
        address owner;                                  // the account address of the operator account owning this render job
        uint256 balance;                                // the amount of HBAR deposited by the job owner in the smart contract to pay render work for this job
        uint256 work;                                   // the estimated amount of work required to render the job (in BBh)
        uint256 cost;                                   // the estimated amount of HBAR the rendering of the job will cost
        uint256 submissionTime;                         // the time when the render job was submitted to the contract

        // render statistics
        uint256 invoicedWork;                           // the amount of work invoiced by all nodes for this render job so far
        uint256 invoicedCost;                           // the amount of HBAR invoiced by all nodes for this render job so far

        // hive cycle information
        mapping(uint256 => RenderJobClaim[]) claims;    // array claims in the given hive cycle
        mapping(uint256 => bool) skipped;               // state variable indicating the render job state for the given hive cycle

        // render job status flags
        bool isArchived;                                // flag to indicate if the render job is archived (i.e., no more changes are expected)
        
    }

    // mapping to a the render job metadata (based on the render job's IPFS CID)
    mapping(string => RenderJob) private RenderJobs;

    // mapping to an array of all the operator's submitted render jobs (based on operator's account address)
    mapping(address => string[]) private operatorRenderJobs;

    // function to add a new render job
    // NOTE: This function expects an estimated job cost from the calling user. 
    //       A malicious user could lie about it and therefore we need to implement further checks and balances to make sure 
    //       the render nodes are not left with an unpaid render job. Following measure may be implemented in- and outside the smart contract:
    //
    //         - the node stakes of the operator can be used to cover unpaid render jobs
    //         - the operator can be banned from the network, if it does not pay its render jobs
    //         - the render nodes will do their own cost estimates before starting a render job and only start rendering if it fits with the estimated costs 
    function addRenderJob(string calldata _jobCID, uint256 _estimatedJobWork)
        external 
        payable 
        nonReentrant
        whenNotPaused
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if a render job with the given CID does NOT already exist
        require(RenderJobs[_jobCID].owner == address(0), "Render job with this CID already exists");

        // check if the estimated work required to render the job and the allocated amount of HBAR is greater than zero
        require(_estimatedJobWork > 0, "Estimated render job work must be greater than zero");
        require(msg.value > 0, "Estimated render job cost must be greater than zero");

        // add the new job to the RenderJobs mapping
        RenderJobs[_jobCID].jobCID = _jobCID;
        RenderJobs[_jobCID].owner = msg.sender;
        RenderJobs[_jobCID].balance = msg.value;
        RenderJobs[_jobCID].work = _estimatedJobWork;
        RenderJobs[_jobCID].cost = msg.value;
        RenderJobs[_jobCID].submissionTime = block.timestamp;
        RenderJobs[_jobCID].invoicedWork = 0;
        RenderJobs[_jobCID].invoicedCost = 0;
        RenderJobs[_jobCID].isArchived = false;

        // add the CID of the new job to the operatorRenderJobs mapping
        operatorRenderJobs[msg.sender].push(_jobCID);

        // emit an event about the added render job
        emit AddedRenderJob(_jobCID, msg.sender, msg.value, _estimatedJobWork, block.timestamp);

    }

    // function to top up the render job balance
    function depositRenderJobFunds(string calldata _jobCID) 
        external 
        payable 
        nonReentrant
        whenNotPaused
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if a render job with the given CID exists
        require(RenderJobs[_jobCID].owner != address(0), "Render job with this CID does not exist");

        // check if the render job is NOT archived
        require(RenderJobs[_jobCID].isArchived == false, "Render job is archived");

        // check if the calling address is the render job owner
        require(RenderJobs[_jobCID].owner == msg.sender, "Function call is only allowed for the render job owner");

        // check if the value is valid
        require(msg.value > 0, "The amount of HBAR deposited must not be zero");

        // add the top up amount to the render job balance
        RenderJobs[_jobCID].balance += msg.value;

        // emit an event about the added render job
        emit DepositedRenderJobFunds(_jobCID, msg.sender, msg.value, block.timestamp);

    }

    // function to claim a render job
    // TODO: This could be optimized by using meta transactions. First, all nodes submit their claims to HCS and then one node sends all claims to the contract in one call.
    //       This would reduce the number of transactions and therefore the costs. Furthermore, it would slightly mitigate the interference options by malicious nodes.
    function claimRenderJob(string calldata _jobCID, uint256 _hiveCycle, uint8 _nodeCount, uint128 _nodeShare, bytes32 _consensusRoot, bytes32 _jobRoot) 
        external 
        nonReentrant
        whenNotPaused
    {

        // check if the calling address is registered as an active node
        require((Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false), "Function call is only allowed for registered nodes");

        // check if the node has sufficient node stake
        require(_isNodeStaked(msg.sender), "Insufficient node stake");

        // check if a render job with the given CID exists and is NOT archived
        require(RenderJobs[_jobCID].owner != address(0), "Render job with this CID does not exist");
        require(RenderJobs[_jobCID].isArchived == false, "Render job is archived");

        // check if the node wants to claim the job for the correct hive cycle
        require(_hiveCycle == getCurrentHiveCycle(), "Not a valid hive cycle");

        // get the render job data
        RenderJob storage renderJob = RenderJobs[_jobCID];

        // NOTE: We implement a skipping mechanism for render jobs with obvious merkle root collisions 
        //       (i.e., if two nodes claim the same render job with different merkle roots). 
        //       Skipped jobs will not be rendered and the contract will reject all invoices presented for skipped jobs.
        //       This mechanism is necessary to prevent malicious nodes from claiming a render job ignoring the consensus.
        for (uint256 i = 0; i < renderJob.claims[_hiveCycle].length; i++) {

            // get the claim data
            RenderJobClaim memory claim = renderJob.claims[_hiveCycle][i];

            // check if the node already claimed the render job in this hive cycle
            require(claim.node != msg.sender, "Render job was already claimed by this node in this hive cycle");

            // if another node claimed the render job with different merkle roots
            if (claim.jobRoot != _jobRoot || claim.consensusRoot != _consensusRoot) {

                // skip the render job for this hive cycle
                renderJob.skipped[_hiveCycle] = true;

                // break the loop
                break;

            }

        }

        // create a new render job claim
        RenderJobClaim memory nodeClaim = RenderJobClaim({
            node: msg.sender,
            nodeCount: _nodeCount,
            nodeShare: _nodeShare,
            jobRoot: _jobRoot,
            consensusRoot: _consensusRoot,
            invoiceCID: "",
            invoicedAmount: 0,
            invoicedTime: 0,
            invoiceRevoked: false
        });
        
        // add the claim to the render job
        renderJob.claims[_hiveCycle].push(nodeClaim);

        // emit an event about the added claim
        // NOTE: This event is highly important. It enables all nodes to validate the claims of other nodes outside the smart contract and to detect malicious nodes.
        //       For now, malicious nodes will be ignored in the next distribution cycle. Later, we might implement a downvoting and/or slashing mechanism.
        emit ClaimedRenderJob(_jobCID, renderJob.owner, _hiveCycle, msg.sender, _nodeCount, _nodeShare, _jobRoot, _consensusRoot);

    }

    // function to check if the render job belongs to the given operator account
    // NOTE: This function should also check if the given operator account is registered as operator
    function isRenderJobOwner(address _operatorAccount, string memory _jobCID) 
        public 
        view 

        returns(bool)
    {

        // return false, if the given account is NOT registered as operator (it may be inactive to enable historical data queries)
        if (operators[_operatorAccount].registrationTime == 0 ) {
            return false;
        }

        // return false, if no render job with the given CID exists
        if (RenderJobs[_jobCID].owner == address(0)) {
            return false;
        }

        // return false, if the render job is NOT owned by the given operator account
        if (RenderJobs[_jobCID].owner != _operatorAccount) {
            return false;
        }

        // check if the render job is also in the operator's render jobs array
        for (uint256 i = 0; i < operatorRenderJobs[_operatorAccount].length; i++) {
            if (keccak256(abi.encodePacked(operatorRenderJobs[_operatorAccount][i])) == keccak256(abi.encodePacked(_jobCID))) {
                return true;
            }
        }

        // otherwise the render job does not belong to the operator account
        return false;

    }


    // TODO: Implement slashing mechanism for nodes that submit invalid claims. 
    //       All nodes listen for the contract events and validate if the job claims are correct. 
    //       If a node detects a wrong claim, it can submit a slashing request to the contract, 
    //       which causes the contract to distribute the node stakes (or parts of it) of bad actors 
    //       to to the nodes that submitted the correct claims in the hive cycle.
    //
    //       - slashing functions should be callable by any registered node / operator (allow this only for trusted nodes / operators at the beginning?)
    //       - slashing functions should be callable only for past hive cycles
    //       - calling node identfies from the emitted contract events the wrong claims 
    //       - calling node obtains the correct proofs and job roots for the wrong claims and submits all of them to the contract
    //       - contract checks if the proofs are valid
    //       - contract obtains the consensus root from all unobjected jobs 
    //       - contract calculates the merkle tree from all known and all corrected job roots
    //       - contract validates for each job if the conensus root is equal to the calculated consensus root
    //       - contract slashes the node stake(s) from all nodes that submitted a wrong claim

    // // (private) helper function to penalize nodes that do not submit the correct merkle root
    // // NOTE: This function should only be called from other functions in this contract. All necessary checks must be done before calling this function.
    // function _slashNode(uint256 _hiveCycle, address _slashedNode, address _notifyingNode) 
    //     private 
    //     nonReentrant
    //     whenNotPaused
    // {

    //     // get node stake
    //     uint256 nodeStake = Nodes[_slashedNode].nodeStake;

    //     // convert the node stake into HBAR with the help of the exchange rate precompile
    //     uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
    //     uint256 stake = tinycentsToTinybars(tinycents);

    //     // if the node has sufficient stake and was not already slashed for this hive cycle
    //     if (nodeStake > stake && hiveCycleTrees[_hiveCycle].slashed[_slashedNode] == false) {

    //         // slash half of the standard stake value
    //         uint256 slashAmount = stake / 2;

    //         // slash the node stake and transfer the slashed amount to the node that recognized the wrong merkle root first
    //         Nodes[_slashedNode].nodeStake -= slashAmount;
    //         Nodes[_notifyingNode].nodeStake += slashAmount;

    //         // mark the node as slashed for this hive cycle, so it cannot be slashed again
    //         hiveCycleTrees[_hiveCycle].slashed[_slashedNode] = true;

    //     }

    // }


    // Render job invoicing
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // TODO: Would meta transactions be a better solution for the render job invoicing?
    //       The client node could submit a meta transaction via HCS to the render node, 
    //       which could then submit the transaction to the contract, which verifies and executes it.

    // function to redeem a render job invoice
    // NOTE: This function expects the invoice to be signed by the job owner and the invoice issuer to be the on executing the transaction.
    function claimRenderInvoice(string calldata _invoiceCID, string calldata _jobCID, uint256 _hiveCycle, uint256 _invoicedWork, uint256 _invoicedAmount, address _jobOwner, bytes calldata _ownerSignature) 
        public
        nonReentrant
        whenNotPaused
    {

        // check if the claimed hive cycle is valid
        require(_hiveCycle < getCurrentHiveCycle(), "Only invoices from past hive cycles can be claimed");

        // check if the calling address is registered as active node
        require((Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false) , "Function call is only allowed for registered nodes");

        // check if the given render job exists and is owned by the given job owner (also checks if this account is registered as operator)
        require(isRenderJobOwner(_jobOwner, _jobCID) == true, "Render job does not exist or does not belong to this operator");

        // check if the caller and the job owner are NOT the same address
        require(msg.sender != _jobOwner, "Cannot claim invoices for own render jobs");

        // try to find a claim for the given render job and hive cycle 
        uint256 claimIndex = _getJobClaimIndex(_jobCID, _hiveCycle, msg.sender);

        // get the render job claim data
        RenderJobClaim storage claim = RenderJobs[_jobCID].claims[_hiveCycle][claimIndex];



        // hash the invoice data
        bytes32 invoiceHash = keccak256(abi.encodePacked(_invoiceCID, _jobCID, _jobOwner, _hiveCycle, msg.sender, _invoicedWork, _invoicedAmount));

        // check if the recovered address is the same as the job owner
        require(_verifySignature(invoiceHash, _ownerSignature) == _jobOwner, "Invalid signature");

        // TODO: Check if the node invoices significantly more work than expected.

        // check if the job balance is sufficient to pay the invoice
        require(RenderJobs[_jobCID].balance >= _invoicedAmount, "Insufficient job balance to pay the invoice");



        // pay the invoice from the job balance to the render job claim balance
        // NOTE: It is first transferred to this balance to prevent the node from withdrawing the funds before the job owner checked the final render result.
        RenderJobs[_jobCID].balance -= _invoicedAmount;
        claim.invoiceCID = _invoiceCID;
        claim.invoicedAmount += _invoicedAmount;
        claim.invoicedTime = block.timestamp;

        // update render job statistics
        RenderJobs[_jobCID].invoicedWork += _invoicedWork;
        RenderJobs[_jobCID].invoicedCost += _invoicedAmount;

        // emit an event about the claimed invoice
        emit ClaimedRenderJobInvoice(_jobCID, _jobOwner, _invoiceCID, _hiveCycle, msg.sender, _invoicedWork, _invoicedAmount, block.timestamp);

    }

    // function to force transfer from the job balance to the invoicing node owner's balance after 24 hours
    // TODO: rename!
    function forceTransferRenderJobBalance(string calldata _jobCID, uint256 _hiveCycle) 
        external
        nonReentrant
        whenNotPaused
    {

        // check if the claimed hive cycle is valid
        require(_hiveCycle < getCurrentHiveCycle(), "Only invoices from past hive cycles can be claimed");

        // check if the calling address is registered as active node
        require((Nodes[msg.sender].registrationTime != 0 && Nodes[msg.sender].isArchived == false) , "Function call is only allowed for registered nodes");

        // check if the given render job exists and is owned by the given job owner (also checks if this account is registered as operator)
        require(isRenderJobOwner(RenderJobs[_jobCID].owner, _jobCID) == true, "Render job does not exist or does not belong to this operator");

        // check if the caller and the job owner are NOT the same address
        require(msg.sender != RenderJobs[_jobCID].owner, "Cannot claim invoices for own render jobs");

        // try to find a claim for the given render job and hive cycle 
        uint256 claimIndex = _getJobClaimIndex(_jobCID, _hiveCycle, msg.sender);

        // get the node data and the claim data
        Operator storage operator = operators[Nodes[msg.sender].operatorAccount];
        RenderJobClaim storage claim = RenderJobs[_jobCID].claims[_hiveCycle][claimIndex];

        // check if the invoice was already paid and the 72 hours have passed
        require(claim.invoicedTime != 0, "Invoice was not paid yet");
        require((claim.invoicedTime + 24 hours) < block.timestamp, "The paymet is locked for 24 hours");
        require(claim.invoicedAmount > 0, "Balance was already transferred");

        // transfer the invoice amount from the invoicedAmount to the node owner's balance
        operator.balance += claim.invoicedAmount;
        claim.invoicedAmount = 0;
    
    }

    // function allowing a render job owner to revoke a payment within 24 hours after the invoice was claimed
    // NOTE: This should kickoff a dispute mechanism, where the nodes can vote if the invoice is valid or not.
    //       For now, it only marks the paid invoice in the claim data as revoked.
    function revokeRenderJobInvoice(string calldata _jobCID, uint256 _hiveCycle) 
        external
        nonReentrant
        whenNotPaused
    {

        // check if the claimed hive cycle is valid
        require(_hiveCycle < getCurrentHiveCycle(), "Only invoices from past hive cycles can be claimed");

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

        // check if the given render job exists and is owned by the given job owner (also checks if this account is registered as operator)
        require(isRenderJobOwner(msg.sender, _jobCID) == true, "Render job does not exist or does not belong to this operator");

        // try to find a claim for the given render job and hive cycle 
        uint256 claimIndex = _getJobClaimIndex(_jobCID, _hiveCycle, msg.sender);

        // get the node data and the claim data
        RenderJobClaim storage claim = RenderJobs[_jobCID].claims[_hiveCycle][claimIndex];

        // check if the invoice was already paid and the 72 hours have passed
        require(claim.invoicedTime != 0, "Invoice was not paid yet");
        require((claim.invoicedTime + 24 hours) > block.timestamp, "The 24 h period for revoking the payment has passed");

        // mark the invoice as revoked
        claim.invoiceRevoked = true;

        // TODO: Implement a dispute mechanism.
        //       IDEA: Anyone can register their operator account as a mediator. In case of a dispute, 
        //       the contract would pick a set of random mediators and emit an event about the dispute.
        //       Upon receipt of the event, the chosen mediators would evaluate the dispute and submit a vote.
        //       The majority vote would be used to resolve the dispute and part of the loosing party's stake
        //       would be distributed among the mediators. 

    }


    // // function to redeem a render job invoice
    // function claimRenderInvoiceBatch(string[] calldata _invoiceCID, string[] calldata _jobCID, uint256[] calldata _hiveCycle, uint256[] calldata _invoicedWork, uint256[] calldata _invoicedAmount, address[] calldata _jobOwner, bytes[] calldata _ownerSignature) 
    //     external
    //     nonReentrant
    //     whenNotPaused
    // {

    //     // check if the calling address is registered as active operator
    //     require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false) , "Function call is only allowed for registered operators");

    //     // make sure the arrays have the same length
    //     require(_invoiceCID.length == _jobCID.length, "Array length mismatch");
    //     require(_invoiceCID.length == _hiveCycle.length, "Array length mismatch");
    //     require(_invoiceCID.length == _invoicedWork.length, "Array length mismatch");
    //     require(_invoiceCID.length == _invoicedAmount.length, "Array length mismatch");
    //     require(_invoiceCID.length == _jobOwner.length, "Array length mismatch");
    //     require(_invoiceCID.length == _ownerSignature.length, "Array length mismatch");

    //     // iterate through all the invoices
    //     for (uint256 i = 0; i < _invoiceCID.length; i++) {
    
    //         // execute the claimRenderInvoice function for each invoice
    //         // NOTE: If one of the invoices fails, the whole batch transaction will be reverted.
    //         claimRenderInvoice(_invoiceCID[i], _jobCID[i], _hiveCycle[i], _invoicedWork[i], _invoicedAmount[i], _jobOwner[i], _ownerSignature[i]);

    //     }


    // }



    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  HELPER FUNCTIONS
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

    // Operator & Node Management
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // (private) helper function to transfer funds from one operator account to another operator account
    // NOTE: This is a private function, because it should only be called internally by other functions within this contract.
    function _transferOperatorFunds(address _receivingAccount, uint256 _amount) 
        private 
    {

        // check if the calling address is registered as active operator
        require((operators[msg.sender].registrationTime != 0 && operators[msg.sender].isArchived == false), "Function call is only allowed for registered operators");

        // check if the receiver account is registered as operator and not archived
        require(msg.sender != _receivingAccount, "Sender and receiver cannot have the same address");
        require(operators[_receivingAccount].registrationTime != 0, "Receiver is not known");
        require(operators[_receivingAccount].isArchived == false, "Receiver was archived and no more changes or queries are allowed");

        // check if the operator balance is sufficient
        require(_amount > 0, "Amount must be greater than zero");
        require(operators[msg.sender].balance >= _amount, "Insufficient balance");

        // get the operator data
        Operator storage sendingOperator = operators[msg.sender];
        Operator storage receivingOperator = operators[_receivingAccount];
    
        // update the operator balance value
        sendingOperator.balance -= _amount;
        receivingOperator.balance += _amount;

        // emit an event about the transfer
        emit BalanceTransfer(msg.sender, _receivingAccount, _amount, block.timestamp);
        
    }

    // (private) helper function to update a addresses last activity timestamp
    function _updateLastActivity(address _account) 
        private 
    {

        // update the last activity timestamp
        if (operators[_account].registrationTime != 0) {
            operators[_account].lastActivity = block.timestamp;
        } else if (Nodes[_account].registrationTime != 0) {
            Nodes[_account].lastActivity = block.timestamp;
        }

    }

    // (private) helper function to check if the node has sufficient stake
    // NOTE: This function should only be called from other functions in this contract. All necessary checks must be done before calling this function.
    function _isNodeStaked(address _nodeAccount) 
        private

        returns(bool)
    {

        // convert the required node stake value into HBAR with the help of the exchange rate precompile
        uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
        uint256 requiredTinybars = tinycentsToTinybars(tinycents);

        // update the status variable
        Nodes[_nodeAccount].isStaked = bool(Nodes[_nodeAccount].nodeStake >= requiredTinybars);

        // check if the node has insufficient stake
        return Nodes[_nodeAccount].isStaked;
    
    }


    // Render Job & Render Invoice Management
    // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // (private) helper function to verify a job distribution consensus proof
    // NOTE: This function should only be called for conensus proof verification.
    function _verifyConsensusProof(bytes32 _jobRoot, bytes32 _consensusRoot, bytes32[] memory _consensusProof) 
        private
        pure 

        returns (bool)  
    {

        // calculate the leaf hash from the job's merkle root
        bytes32 leaf = keccak256(abi.encodePacked(_jobRoot));

        // return the result of the verification
        return MerkleProof.verify(_consensusProof, _consensusRoot, leaf);

    }

    // (private) helper function to verify a job assignment proof
    // NOTE: This function should only be called for job proof verification.
    function _verifyJobProof(string memory _jobCID, uint256 _hiveCycle, uint8 _nodeCount, uint128 _nodeShare, address _nodeAccount, bytes32 _jobRoot, bytes32[] memory _jobProof) 
        private
        pure 

        returns (bool)  
    {

        // TODO: Check if hash collisions are possible
        // calculate the leaf hash from the job's CID, the hive cycle and the claiming node account
        bytes32 leaf = keccak256(abi.encodePacked(_jobCID, _hiveCycle, _nodeAccount, _nodeCount, _nodeShare));

        // return the result of the verification
        return MerkleProof.verify(_jobProof, _jobRoot, leaf);

    }

    // (private) helper function to split a signature into its components
    function _verifySignature(bytes32 _hash, bytes memory _signature)
        private
        pure
        returns (address)
    {
        require(_signature.length == 65, "Invalid signature length");

        // declare variables to store the signature components
        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            // first 32 bytes, after the length prefix.
            r := mload(add(_signature, 32))
            // second 32 bytes.
            s := mload(add(_signature, 64))
            // final byte (first byte of the next 32 bytes).
            v := byte(0, mload(add(_signature, 96)))
        }

        // recover the address of the invoice signer
        address signer = ecrecover(_hash, v, r, s);

        return signer;
    }

    // (private) helper function to check if the node claimed the render job in the given hive cycle
    function _isJobClaimed(string memory _jobCID, uint256 _hiveCycle, address _nodeAccount) 
        private 
        view 
        
        returns (bool) 
    {

        // get job data
        RenderJob storage renderJob = RenderJobs[_jobCID];

        // iterate through all the claims for this job made in the given hive cycle
        for (uint256 i = 0; i < renderJob.claims[_hiveCycle].length; i++) {

            // check if the node already claimed the render job and if the job was not skipped
            if (renderJob.claims[_hiveCycle][i].node == _nodeAccount && renderJob.skipped[_hiveCycle] == false) {
                return true;
            }
        }

        return false;
    }

    // (private) helper function to get the render job claim index from the job claims array
    // NOTE: This function should only be called by this contract.
    //       All necessary sanity checks MUST be done BEFORE calling this function.
    function _getJobClaimIndex(string memory _jobCID, uint256 _hiveCycle, address _nodeAccount) 
        private
        view 
        returns (uint256) 
    {
        // get the render job data
        RenderJob storage renderJob = RenderJobs[_jobCID];

        // iterate through all the claims in the given hive cycle
        for (uint256 i = 0; i < renderJob.claims[_hiveCycle].length; i++) {

            // get the claim data
            RenderJobClaim memory claim = renderJob.claims[_hiveCycle][i];

            // check if the node claimed the render job and if the job was not skipped
            if (claim.node == _nodeAccount && renderJob.skipped[_hiveCycle] == false) {
                // If a matching claim is found, return its index
                return i;
            }
        }

        // If no claim was found, revert the transaction
        revert("Render job was not claimed by this node in this hive cycle");

    }

    // (private) helper function to get node share from the job claims
    // NOTE: This function should only be called by this contract. 
    //       All necessary sanity checks MUST be done BEFORE calling this function.
    function _getNodeShare(string memory _jobCID, uint256 _hiveCycle, address _nodeAccount) 
        private
        view 

        returns (uint128)  
    {

        // get the render job data
        RenderJob storage renderJob = RenderJobs[_jobCID];

        // iterate through all the claims in the given hive cycle
        for (uint256 i = 0; i < renderJob.claims[_hiveCycle].length; i++) {

            // get the claim data
            RenderJobClaim memory claim = renderJob.claims[_hiveCycle][i];

            // check if the node already claimed the render job in this hive cycle
            if (claim.node == _nodeAccount) {

                // return the node share
                return claim.nodeShare;

            }

        }

        // otherwise return zero
        return 0;

    }

    // TODO: Introduced a balance for render jobs and we now pay render invoices from the render job balance.
    // // (private) helper function to execute the payment of a render invoice via operator balances
    // // NOTE: This is a private function, because it should only be called by other contract function. All sanity checks MUST be done before calling this function!
    // function _executePayment(string memory _invoiceCID, InvoiceState _invoiceState) 
    //     private 
    // {

    //     // Access invoicing node and its operator
    //     Node storage invoiceNode = Nodes[RenderInvoices[_invoiceCID].nodeAccount];
    //     Operator storage invoiceOperator = operators[invoiceNode.operatorAccount];

    //     // Execute the payment by updating the balances
    //     operators[msg.sender].balance -= RenderInvoices[_invoiceCID].jobCost;
    //     invoiceOperator.balance += RenderInvoices[_invoiceCID].jobCost;

    //     // Update the render invoice state
    //     RenderInvoices[_invoiceCID].state = _invoiceState;

    //     // Update the render job owner's statistics
    //     operators[msg.sender].acceptedRenderInvoices++;

    //     // Update the render node's render job statistics
    //     invoiceNode.acceptedRenderInvoices++;

    // }

    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  CONTRACT MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // // TODO: The "pause" option adds a level of security, but also one of centralized control over the contract. 
    // //       Should we give up this option in favor of absolute decentralization?
    // //       - if yes, then remove the owner variable and all functions that use it

    // // functions to enable the pausing and unpausing of the smart contract (in case of a contract redeployment, a bug, or an exploit)
    // function pause() 
    //     public 
    //     onlyOwner 
    // {
    //     _pause();
    // }
    // function unpause() 
    //     public 
    //     onlyOwner 
    // {
    //     _unpause();
    // }
    
    // function to check the contracts HBAR balance
    function getBalance() 
        public 
        view 
        
        returns (uint256) 
    {
        return address(this).balance;
    }





}