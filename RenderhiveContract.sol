// SPDX-License-Identifier: MIT OR Apache-2.0
// 2023 © Christian Stolze

pragma solidity >= 0.9.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "@hashgraph/smart-contracts/exchange-rate-precomile/SelfFunding.sol";

contract RenderhiveContract is ReentrancyGuard, Ownable, Pausable, SelfFunding {

    constructor() {
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  CONSTANTS & ENUMERATIONS
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // Required amount of USD (in cents) to be deposited by each node to particpate in the network.
    // This so-called safte deposit is used to disincentivize malicious behavior and to cover the 
    // costs of refunds in case of a maliciously behaving node.
    uint256 public constant REQUIRED_SAFETY_DEPOSITY_USD_CENTS = 500;

    // invoicing related enumerations
    enum InvoiceState { 
        INVALID_STATE,                              // not initialized
        REQUESTED,                                  // the render node submitted the invoice and is waiting for the operator to pay
        ACCEPTED,                                   // the operator accepted the invoice and paid the render node
        ACCEPTED_AFTER_RERENDER,                    // the operator was forced to accept the invoice after the rerendering was unsuccessful
        DECLINED                                    // the operator declined the invoice and did not pay the render node
    }
    enum InvoiceDeclineReason { 
        INVALID_STATE,                              // not initialized
        INVALID_NODE,                               // the node that submitted the invoice was not allowed to render the job (according to the network consensus)
        INVALID_WORK,                               // the job owner does not agree with the amount of work invoiced by the render node
        INVALID_COSTS,                              // the job owner does not agree with the costs invoiced by the render node
        INVALID_RENDER_RESULT                       // the job owner does not approve the render result submitted by the render node
    }
    enum InvoiceErrors { 
        NO_ERROR,                                   // no error occured
        INVALID_JOB_OR_INVOICE,                     // the given render job or render invoice does not exist
        ALREADY_ACCEPTED_OR_DECLINED,               // the given render invoice was already accepted or declined before
        INSUFFICIENT_BALANCE,                       // the operator has insufficient balance to pay the render invoice
        INVALID_RENDER_RESULT_NOT_ALLOWED_TWICE     // the render job was already re-rendered and can not be re-rendered again
    }


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  EVENTS
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // operator events
    event RegisteredUser(address indexed operatorAccount, uint256 registrationTime);
    event UnregisteredUser(address indexed operatorAccount, uint256 deletionTime);

    // node events
    event AddedNode(address indexed operator, address indexed nodeAccount, uint256 registrationTime);
    event DeletedNode(address indexed operator, address indexed nodeAccount, uint256 deletionTime);


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  OPERATOR MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // these functions enable the registration and magegement of operators on the Renderhive network
    struct Operator {
        uint256 balance;
        uint256 registrationTime;

        // operator statistics
        uint256 acceptedRenderInvoices;    // number of invoices paid by this operator
        uint256 declinedRenderInvoices;    // number of invoices this operator declined to pay

    }

    // mapping to store operator information via the operator's wallet address
    mapping(address => Operator) private operators;

    // function to register a new operator account
    function registerOperator() 
        public 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling account is already registered as operator
        require(operators[msg.sender].registrationTime == 0, "Operator with this address is already registered");

        // create a new operator
        operators[msg.sender] = Operator({
            registrationTime: block.timestamp,
        });

        // emit an event about the registration
        emit RegisteredUser(msg.sender, operators[msg.sender].registrationTime);

    }

    // function to delete the calling operator account
    function unregisterOperator() 
        public 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // TODO: Check all nodes owned by the operator and delete them. (Or should we keep them for data integrity?)

        // transfer any remaining balance back to the operator
        if (operators[msg.sender].balance > 0) {
            payable(msg.sender).transfer(operators[msg.sender].balance);
        }

        // TODO: Check, if it would make more sense to keep the record and just mark the operator as inactive
        // delete the account from the mapping
        delete operators[msg.sender];

        // emit an event about the deletion
        emit UnregisteredUser(msg.sender, block.timestamp);

    }

    // function to check if the given addres is a registered operator
    function isOperator(address _operatorAccount) 
        public 
        view 

        returns(bool)
    {

        // check if the given account is registered as operator
        require(operators[_operatorAccount].registrationTime != 0, "Operator with this address is not registered");

        // if required statement passed successfully, return true
        return true;

    }

    // function to deposit the specified amount of HBAR in the operator's balance
    function depositOperatorFunds() 
        public 
        payable
        nonReentrant 
        whenNotPaused 
    {
        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // make sure a deposit was provided
        require(msg.value > 0, "The amount of HBAR deposited must not be zero");

        // update the operator balance value
        operators[msg.sender].balance = operators[msg.sender].balance + msg.value;
        
    }

    // function to withdraw specified amount of HBAR from the operator's balance
    function withdrawOperatorFunds(uint256 _amount) 
        public 
        nonReentrant 
        whenNotPaused 
    {
        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if the operator balance is sufficient
        require(operatorData.balance >= _amount, "Insufficient balance");

        // get the operator data
        Operator storage operatorData = operators[msg.sender];

        // sum up all deposits of pending render jobs of this operator
        uint256 renderJobCosts = getReservedOperatorFunds(msg.sender);

        // check if the balance is sufficient taken into consideration the pending render jobs
        require(operatorData.balance >= renderJobCosts + _amount, "Specified amount can not be withdrawn due to unpaid render jobs");

        // update the operator balance value
        operatorData.balance = operatorData.balance - _amount;

        // withdraw the specified amount to the operator account
        payable(msg.sender).transfer(_amount);
        
    }

    // function to get the total balance of an operator's nodes stored in the contract (only callable by the operator)
    function getOperatorBalance(address _operatorAccount) 
        public 
        view 
        returns(uint256) 
    {

        // check if the requested account is registered as operator
        require(operators[_operatorAccount].registrationTime != 0, "Operator with this address is not registered");

        // return the balance
        return operators[_operatorAccount].balance;

    }

    // function to get the reserved amount of the operator funds (i.e., the sum of all render job deposits)
    function getReservedOperatorFunds(address _operatorAccount) 
        public 
        view 
        returns(uint256) 
    {

        // check if the requested account is registered as operator
        require(operators[_operatorAccount].registrationTime != 0, "Operator with this address is not registered");

        // get the operator data
        Operator storage operatorData = operators[_operatorAccount];

        // sum up all deposits of pending render jobs of this operator
        uint256 renderJobCosts = 0;
        for (uint256 i = 0; i < operatorRenderJobs[_operatorAccount].length; i++) {
            if (RenderJobs[operatorRenderJobs[_operatorAccount][i]].isArchived == false) {
                renderJobCosts = renderJobCosts + RenderJobs[operatorRenderJobs[_operatorAccount][i]].jobCost;
            }
        }

        // return the accumulated amount of reserved funds (from the render job deposits)
        return renderJobCosts;

    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  NODE MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // TODO: Think about shifting the nodeGuarentee field to the Operator struct
    //         - might be easier to manage, in case jobs need to be paid
    //         - is it actually fair/required to have a guarantee per node or should it rather be per operator?

    // these functions enable the registration and management of nodes owned by operators on the Renderhive network
    struct Node {
        address operatorAccount;
        uint256 nodeGuarantee;
        uint256 registrationTime;
        bool isActive;

        // node statistics
        uint256 acceptedRenderInvoices;    // number of successfully processed render jobs of this node
        uint256 declinedRenderInvoices;    // number of render jobs NOT successfully processed by this node

    }

    // mapping to node data (based on the node's account address)
    mapping(address => Node) private Nodes;

    // mapping to an array of all the nodes owned by a specific operator (based on operator's account address)
    mapping(address => address[]) private operatorNodes;

    // function to add a new node to an operator account
    function addNode(address _nodeAccount) 
        public 
        payable 
        nonReentrant 
        whenNotPaused 
	    returns(uint256)
    {

        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if the given node account is NOT already registered as node
        require(Nodes[_nodeAccount].registrationTime == 0, "Node with this address is already registered");

        // convert the node guarantee into HBAR with the help of the exchange rate precompile
        uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
        uint256 requiredTinybars = tinycentsToTinybars(tinycents);

        // check if the required node guarantee was provided
        require(msg.value >= requiredTinybars, "Insufficient node guarantee provided");

        // add the new node to the Nodes mapping
        Nodes[_nodeAccount] = Node({
            operatorAccount: msg.sender,
            nodeGuarantee: msg.value,
            registrationTime: block.timestamp,
            isActive: true
        });

        // add the node account to operatorNodes mapping
        operatorNodes[msg.sender].push(_nodeAccount);

        // emit an event about the added node
        emit AddedNode(msg.sender, _nodeAccount, block.timestamp);

        // return the node ID
        return operatorNodes[msg.sender].length - 1;

    }

    // function to delete a node from an operator account
    // TODO: Can we delete nodes or would the loss of data from the smart contract be a problem?
    function deleteNode(address _nodeAccount) 
        public 
        nonReentrant 
        whenNotPaused 
    {
        // check if the account is registered
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as the operator's node");

        // Operator's node array
        address[] storage thisOperatorNodes = operatorNodes[msg.sender];

        // find the index of the node in the operatorNodes array
        uint256 index = 0;
        while (thisOperatorNodes[index] != _nodeAccount) {
            index++;
        }

        // remove the node from the operatorNodes array
        thisOperatorNodes[index] = thisOperatorNodes[operatorNodes[msg.sender].length - 1];
        thisOperatorNodes.pop();

        // move the node guarantee to the operator balance
        operators[msg.sender].balance = operators[msg.sender].balance + Nodes[_nodeAccount].nodeGuarantee;
        Nodes[_nodeAccount].nodeGuarantee = 0;

        // delete the node from the Nodes mapping
        delete Nodes[_nodeAccount];

        // emit an event about the deleted node
        emit DeletedNode(msg.sender, _nodeAccount, block.timestamp);

    }

    // function to check if the node is a valid node of the given operator account
    function isNode(address _operatorAccount, address _nodeAccount) 
        public 
        view 

        returns(bool)
    {

        // check if the given account is registered as operator
        require(operators[_operatorAccount].registrationTime != 0, "Operator with this address is not registered");

        // check if the given node account is registered
        require(Nodes[_nodeAccount].registrationTime != 0, "Node with this address is not registered");

        // check if the node data states the correct operator account
        require(Nodes[_nodeAccount].operatorAccount == _operatorAccount, "Node with this address is not registered as the operator's node");

        // get array of operator nodes 
        address[] storage thisOperatorNodes = operatorNodes[_operatorAccount];

        // check if the node is in the array of the operator's nodes
        for (uint256 i = 0; i < thisOperatorNodes.length; i++) {
            if (thisOperatorNodes[i] == _nodeAccount) {
                return true;
            }
        }

        // otherwise the node is not owned by the operator
        return false;

    }

    // function to deposit the node guarantee for a node from the operator account
    function depositNodeGuarantee(address _nodeAccount) 
        public 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as the operator's node");

        // get the node data
        Node storage nodeData = Nodes[_nodeAccount];

        // convert the required node guarantee value into HBAR with the help of the exchange rate precompile
        uint256 tinycents = REQUIRED_SAFETY_DEPOSITY_USD_CENTS * TINY_PARTS_PER_WHOLE;
        uint256 requiredTinybars = tinycentsToTinybars(tinycents);

        // check if the required node guarantee was provided
        require((nodeData.nodeGuarantee + msg.value) >= requiredTinybars, "Insufficient node guarantee provided");

        // update the node guarantee with the transferred value and set node as active
        nodeData.nodeGuarantee = nodeData.nodeGuarantee + msg.value;
        nodeData.isActive = true;
    
    }

    // function to withdraw the node guarantee of a node to the operator account
    function withdrawNodeGuarantee(address _nodeAccount) 
        public 
        nonReentrant 
        whenNotPaused 
    {

        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if the given node account is registered as the calling account's node
        require(isNode(msg.sender, _nodeAccount), "Node with this address is not registered as the operator's node");

        // get the node data
        Node storage nodeData = Nodes[_nodeAccount];
        uint256 nodeGuarantee = nodeData.nodeGuarantee;

        // check if the node guarantee is greater than zero
        require(nodeGuarantee > 0, "No node guarantee to withdraw");

        // update the nodes node guarantee value and make it inactive
        nodeData.nodeGuarantee = 0;
        nodeData.isActive = false;

        // withdraw the node guarantee to the operator account and make the node inactive
        payable(msg.sender).transfer(nodeGuarantee);
    
    }



    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  RENDER JOB MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // these functions enable the management of render jobs, which are submitted by users and executed by nodes
    struct RenderJob {
        string jobCID;          // the CID of the render job request document
        address owner;          // the account address of the operator account owning this render job
        address jobTopic;       // the address of the render job topic on Hedera
        uint256 jobWork;        // the (estimated) work in BBh required to render this job
        uint256 jobCost;        // the (estimated maximum) cost of the render job
        bool isArchived;        // flag to indicate if the render job is archived (i.e., no more changes are expected)
    }
    struct RenderInvoice {
        string invoiceCID;                  // the CID of the render job invoice submitted by a render node
        address nodeAccount;                // the account address of the render node that submitted the invoice
        uint256 jobWork;                    // the amount of BBh invoiced by the render node
        uint256 jobCost;                    // the amount of HBAR invoiced by the render node

        InvoiceState state;                 // the state of the render job invoice
        InvoiceDeclineReason declineReason; // the reason why the render job invoice was declined

        string prevInvoiceCID;              // the CID of the previously declined render job invoice
        string nextInvoiceCID;              // the CID of the render job invoice submitted after this invoice was declined
    }

    // mapping to a the render job metadata (based on the render job's IPFS CID)
    mapping(string => RenderJob) private RenderJobs;
    mapping(string => RenderInvoice) private RenderInvoices;

    // mapping to an array of all the operator's submitted render jobs (based on operator's account address)
    mapping(address => string[]) private operatorRenderJobs;

    // mapping of all render job invoices for a particular render job (based on the render job's IPFS CID)
    mapping(string => string[]) private renderJobInvoices;

    // function to add a new render job
    // NOTE: This function expects an estimated job cost from the calling user. 
    //       A malicious user could lie about it and therefore we need to implement further checks and balances to make sure 
    //       the render nodes are not left with an unpaid render job. Following measure may be implemented in- and outside the smart contract:
    //
    //         - the node guarentees of the operator can be used to cover unpaid render jobs
    //         - the operator can be banned from the network, if it does not pay its render jobs
    //         - the render nodes will do their own cost estimates before starting a render job and only start rendering if it fits with the estimated costs 
    function addRenderJob(string memory _jobCID, address _jobTopic, uint256 _estimatedJobWork, uint256 _estimatedJobCost) 
        public 
        payable 
        nonReentrant
        whenNotPaused
    {
        // check if the calling account is registered as operator
        require(operators[msg.sender].registrationTime != 0, "Operator with this address is not registered");

        // check if a render job with the given CID does NOT already exist
        require(RenderJobs[_jobCID].owner == address(0), "Render job with this CID already exists");

        // check if the estimated work required to render the job and the allocated amount of HBAR is greater than zero
        require(_estimatedJobWork > 0, "Estimated render job work must be greater than zero");
        require(_estimatedJobCost > 0, "Estimated render job cost must be greater than zero");

        // sum up all deposits of already pending render jobs of this operator
        uint256 renderJobCosts = getReservedOperatorFunds(msg.sender);

        // check if the operator has sufficient balance to cover the (estimated) render job costs
        require((operators[msg.sender].balance + msg.value) >= (renderJobCosts + _estimatedJobCost), "Insufficient balance to cover all estimated render job costs");

        // add the new job to the RenderJobs mapping
        RenderJobs[_jobCID] = RenderJob({
            jobCID: _jobCID,
            jobTopic: _jobTopic,
            jobWork: _estimatedJobWork,
            jobCost: _estimatedJobCost,
            isArchived: false
        });

        // add the CID of the new job to the operatorRenderJobs mapping
        operatorRenderJobs[msg.sender].push(_jobCID);

        // update the operator balance with the deposit for this job
        operators[msg.sender].balance = operators[msg.sender].balance + msg.value;
    }

    // function to archive a render job
    // TODO: Think about if the "archiving" of a render job is a reasonable concept.
    //       One issue is that the render job owner could archive before all invoices are submitted.
    // function archiveRenderJob(string memory _jobCID) 
    //     public 
    //     nonReentrant
    //     whenNotPaused
    // {

    //     // check if the given render job exists and is owned by the calling account (also checks if this account is registered as operator)
    //     require(isRenderJobOwner(msg.sender, _jobCID), "Render invoice does not belong to operator's render job");

    //     // check if the render job is NOT archived already
    //     require(RenderJobs[_jobCID].isArchived == false, "Render job is already archived");

    //     // check if all render invoices for this render job are either accepted or declined
    //     bool hasPendingInvoices = false;
    //     for (uint256 i = 0; i < renderJobInvoices[_jobCID].length; i++) {
    //         if (renderJobInvoices[_jobCID][i].state == InvoiceState.REQUESTED) {
    //             hasPendingInvoices = true;
    //             break;
    //         }
    //     }
    //     require(!hasPendingInvoices, "Cannot archive render jobs with pending invoices");

    //     // archive this render job
    //     RenderJobs[_jobCID].isArchived = true;

    //     // remove the render job from the operator's render jobs array
    //     string[] storage thisOperatorRenderJobs = operatorRenderJobs[msg.sender];
    //     for (uint256 i = 0; i < thisOperatorRenderJobs.length; i++) {
    //         if (keccak256(abi.encodePacked(thisOperatorRenderJobs[i])) == keccak256(abi.encodePacked(_jobCID))) {
    //             thisOperatorRenderJobs[i] = thisOperatorRenderJobs[thisOperatorRenderJobs.length - 1];
    //             thisOperatorRenderJobs.pop();
    //             break;
    //         }
    //     }

    // }


    // TODO: How do deal with malicious nodes that send render invoices although they never took part in the render job?
    //       - this could be done on the job owner side: The node that submitted the job automatically rejects all invoices
    //         which where not part of the networks job distribution consensus
    // function to add an invoice to a render job, which also represents a payment request
    function addRenderInvoice(string memory _jobCID, string memory _invoiceCID, uint256 _invoicedWork, uint256 _invoicedCost)
        public 
        nonReentrant
        whenNotPaused
    {

        // check if the calling account is registered as a node
        require(Nodes[msg.sender].registrationTime != 0, "Node with this address is not registered");

        // check if a render job with the given CID exists
        require(RenderJobs[_jobCID].owner != address(0), "Render job with this CID does not exist");

        // check if the render job is NOT archived
        require(RenderJobs[_jobCID].isArchived == false, "Render job is archived");

        // check if a render invoice with the given CID does NOT already exist
        require(RenderInvoices[_invoiceCID].state == InvoiceState.INVALID_STATE, "Render invoice with this CID already exists");

        // check if valid job work (in BBh) and job cost were provided
        require(_invoicedWork > 0, "Cannot invoice zero or negative job work");
        require(_invoicedCost > 0, "Cannot invoice zero or negative job costs");

        // add the render invoice to the RenderInvoices mapping
        RenderInvoices[_invoiceCID] = RenderInvoice({
            invoiceCID: _invoiceCID,
            nodeAccount: msg.sender,
            jobWork: _invoicedWork,
            jobCost: _invoicedCost,
            state: InvoiceState.REQUESTED
        });

        // add the invoice CID to the renderJobInvoices mapping
        renderJobInvoices[_jobCID].push(_invoiceCID);

    }

    // function to add an invoice to a render job, which also represents a payment request
    // NOTE: This is a function overloading for the case that the operator declined the original invoice and a new invoice is added
    function addRenderInvoice(string memory _jobCID, string memory _invoiceCID, uint256 _invoicedWork, uint256 _invoicedCost, string memory _declinedInvoiceCID)
        public 
        nonReentrant
        whenNotPaused
    {

        // check if the calling account is registered as a node
        require(Nodes[msg.sender].registrationTime != 0, "Node with this address is not registered");

        // check if a render job with the given CID exists
        require(RenderJobs[_jobCID].owner != address(0), "Render job with this CID does not exist");

        // check if a render invoice with the given CID does NOT already exist
        require(RenderInvoices[_invoiceCID].state == InvoiceState.INVALID_STATE, "Render invoice with this CID already exists");

        // check if the original invoice exists (this also checks if the render job exists and is not archived)
        require(isRenderJobInvoice(_jobCID, _declinedInvoiceCID), "Original invoice does not exist or does not belong to the render job");

        // check, if the original invoice is in DECLINED state
        require(RenderInvoices[_declinedInvoiceCID].state == InvoiceState.DECLINED, "Cannot add invoice, because the original invoice was not declined");

        // add the new invoice
        addRenderInvoice(_jobCID, _invoiceCID, _invoicedWork, _invoicedCost);

        // link the new invoice and the original invoice to each other
        RenderInvoices[_declinedInvoiceCID].nextInvoiceCID = _invoiceCID;
        RenderInvoices[_invoiceCID].prevInvoiceCID = _declinedInvoiceCID;

    }

    // function to accept and pay a render invoice filed for a specific render job
    // NOTE: this function may only be successfully called by the operator who owns the render job
    function acceptRenderInvoices(string memory _jobCID, string[] memory _invoiceCIDs) 
        public 
        nonReentrant
        whenNotPaused

        returns(InvoiceErrors[] memory)
    {

        // check if the given render job exists and is owned by the calling account (also checks if this account is registered as operator)
        require(isRenderJobOwner(msg.sender, _jobCID), "Render job does not exist or does not belong to this operator");

        // get job owner and job data
        Operator storage jobOwner = operators[msg.sender];
        RenderJob storage jobData = RenderJobs[_jobCID];

        // initialize error values to return
        InvoiceErrors[] memory errors = new InvoiceErrors[](_invoiceCIDs.length);

        // loop through all the invoiceCIDs
        for (uint256 i = 0; i < _invoiceCIDs.length; i++) {

            // get the invoice CID and invoice data
            string memory _invoiceCID = _invoiceCIDs[i];
            RenderInvoice storage invoiceData = RenderInvoices[_invoiceCID];

            // skip this invoice, if the given render invoice CID does not exist or does not belong to the given render job
            if (!isRenderJobInvoice(_jobCID, _invoiceCID)) {
            // set the invoice state to true
                errors[i] = InvoiceErrors.INVALID_JOB_OR_INVOICE;
                continue;
            }

            // skip this invoice, if it was already accepted or declined
            if (invoiceData.state != InvoiceState.REQUESTED) {
                errors[i] = InvoiceErrors.ALREADY_ACCEPTED_OR_DECLINED;
                continue;
            }

            // skip this invoice, if payer has insufficient balance to pay the job
            if (jobOwner.balance < invoiceData.jobCost) {
                errors[i] = InvoiceErrors.INSUFFICIENT_BALANCE;
                continue;
            }

            // pay the given invoice
            _executePayment(_invoiceCID, InvoiceState.ACCEPTED);

        }

        // TODO: Think about if the "archiving" of a render job is a reasonable concept
        //        - if yes, then check if the render job is now fully paid and archive it
        //        - if no, what do we do with declined invoices?

        // return the array of error codes
        return errors;

    }

    // function to decline a render invoice filed for a specific render job
    // NOTE: this function may only be called by the operator who initially submitted the render job
    function declineRenderInvoice(string memory _jobCID, string[] memory _invoiceCIDs, InvoiceDeclineReason[] memory _invoiceDeclineReasons)
        public 
        nonReentrant
        whenNotPaused

        returns(InvoiceErrors[] memory)
    {

        // check if the given render job exists and is owned by the calling account (also checks if this account is registered as operator)
        require(isRenderJobOwner(msg.sender, _jobCID), "Render job does not exist or does not belong to this operator");

        // check if the passed arrays are of the same size
        require(_invoiceCIDs.length == _invoiceDeclineReasons.length, "The number of invoice CIDs and decline reasons must be the same");

        // get job owner and job data
        Operator storage jobOwner = operators[msg.sender];
        RenderJob storage jobData = RenderJobs[_jobCID];

        // initialize error values to return
        InvoiceErrors[] memory errors = new InvoiceErrors[](_invoiceCIDs.length);

        // loop through all the invoiceCIDs
        for (uint256 i = 0; i < _invoiceCIDs.length; i++) {

            // get the invoice CID and invoice data
            string memory _invoiceCID = _invoiceCIDs[i];
            RenderInvoice storage invoiceData = RenderInvoices[_invoiceCID];

            // check if the job was rerendered
            bool memory isRerendered = _isRerenderedJob(_invoiceCID);

            // skip this invoice, if the given render invoice CID does not exist or does not belong to the given render job
            if (!isRenderJobInvoice(_jobCID, _invoiceCID)) {
                errors[i] = InvoiceErrors.INVALID_JOB_OR_INVOICE;
                continue;
            }

            // skip this invoice, if it was already accepted or declined
            if (invoiceData.state != InvoiceState.REQUESTED) {
                errors[i] = InvoiceErrors.ALREADY_ACCEPTED_OR_DECLINED;
                continue;
            }

            // access invoicing node and its operator
            Node storage invoiceNode = Nodes[invoiceData.nodeAccount];
            Operator storage invoiceOperator = operators[invoiceNode.operatorAccount];

            // TODO: That is probably not the best way to handle this case. Re-evaluate later!
            // check if the rendered invoice shall be declined because of an invalid render result
            if (_invoiceDeclineReasons[i] == InvoiceDeclineReason.INVALID_RENDER_RESULT) {

                // if the render job was already re-rendered, accept and pay the both invoices
                if (isRerendered) {

                    // get the CID of the previously declined invoice
                    _prevInvoiceCID = _getRerenderedInvoice(_invoiceCID);

                    // pay the previously declined invoice AND the current invoice
                    _executePayment(_prevInvoiceCID, InvoiceState.ACCEPTED_AFTER_RERENDER);
                    _executePayment(_invoiceCID, InvoiceState.ACCEPTED_AFTER_RERENDER);

                    // next invoice
                    continue;
                }
            
            } else {
                
                // update the render invoice state and enter the reason for declining
                invoiceData.state = InvoiceState.DECLINED;
                invoiceData.declineReason = _invoiceDeclineReasons[i];

                // update the render job owner's statistics
                jobOwner.declinedRenderInvoices = jobOwner.declinedRenderInvoices + 1;

                // update the render node's render job statistics
                invoiceNode.declinedRenderInvoices = invoiceNode.declinedRenderInvoices + 1;
            
            }

        }
        
        // return the array of error codes
        return errors;

    }

    // function to check if the render job belongs to the given operator account
    // NOTE: This function should also check if the given operator account is registered as operator
    function isRenderJobOwner(address _operatorAccount, string memory _jobCID) 
        public 
        view 

        returns(bool)
    {

        // return false, if the given account is NOT registered as operator
        if (operators[_operatorAccount].registrationTime == 0) {
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

    // function to check if the render invoice exists and belongs to the given render job
    function isRenderJobInvoice(string memory _jobCID, string memory _invoiceCID) 
        public 
        view 

        returns(bool)
    {

        // return false, if no render job with the given CID exists
        if (RenderJobs[_jobCID].owner == address(0)) {
            return false;
        }

        // return false, if the render job is archived
        if (RenderJobs[_jobCID].isArchived == true) {
            return false;
        }

        // return false, if no render invoice with the given CID exists
        if (RenderInvoices[_invoiceCID].state == InvoiceState.INVALID_STATE) {
            return false;
        }

        // return false, if the given render invoice is in the render job's invoices array
        for (uint256 i = 0; i < renderJobInvoices[_jobCID].length; i++) {
            if (keccak256(abi.encodePacked(renderJobInvoices[_jobCID][i])) == keccak256(abi.encodePacked(_invoiceCID))) {
                return true;
            }
        }

        // otherwise the render invoice does not belong to the render job
        return false;

    }

    // (private) helper function to check if a previous invoice was declined because of an invalid render result
    // NOTE: This functions does not check if the given invoice CID is valid! This must happen before calling it in another function!
    function _isRerenderedJob(string memory _invoiceCID) 
        private 
        view 

        returns(bool)
    {

        // while a previouse invoice is linked, check if it was declined because of an invalid render result
        string memory prevInvoiceCID = RenderInvoices[_invoiceCID].prevInvoiceCID;

        // while a previouse invoice exists, check if it was declined because of an invalid render result
        while (RenderInvoices[prevInvoiceCID].state != InvoiceState.INVALID_STATE) {

            // if this invoice was re-rendered, return true
            if (RenderInvoices[prevInvoiceCID].state == InvoiceState.ACCEPTED_AFTE_RERENDER || RenderInvoices[prevInvoiceCID].declineReason == InvoiceDeclineReason.INVALID_RENDER_RESULT) {
                return true;
            }

            // choose previous invoice
            prevInvoiceCID = RenderInvoices[prevInvoiceCID].prevInvoiceCID;

        }

        // otherwise the job was never re-rendered
        return false;

    }


    // (private) helper function to check if a previous invoice was declined because of an invalid render result
    // NOTE: This functions does not check if the given invoice CID is valid! This must happen before calling it in another function!
    function _getRerenderedInvoice(string memory _invoiceCID) 
        private 
        view 

        returns(string)
    {

        // while a previouse invoice is linked, check if it was declined because of an invalid render result
        string memory prevInvoiceCID = RenderInvoices[_invoiceCID].prevInvoiceCID;

        // while a previouse invoice exists, check if it was declined because of an invalid render result
        while (RenderInvoices[prevInvoiceCID].state != InvoiceState.INVALID_STATE) {

            // if this invoice was re-rendered, return true
            if (RenderInvoices[prevInvoiceCID].state == InvoiceState.ACCEPTED_AFTE_RERENDER || RenderInvoices[prevInvoiceCID].declineReason == InvoiceDeclineReason.INVALID_RENDER_RESULT) {
                return prevInvoiceCID;
            }

            // choose previous invoice
            prevInvoiceCID = RenderInvoices[prevInvoiceCID].prevInvoiceCID;

        }

        // otherwise the job was never re-rendered
        return "";

    }

    // (private) helper function to execute the payment of a render invoice
    // NOTE: This is a private function, because it should only be called by the acceptRenderInvoices function
    function _executePayment(string memory _invoiceCID, InvoiceState memory _invoiceState) 
        private 
    {

        // Access invoicing node and its operator
        Node storage invoiceNode = Nodes[RenderInvoices[_invoiceCID].nodeAccount];
        Operator storage invoiceOperator = operators[invoiceNode.operatorAccount];

        // Execute the payment by updating the balances
        operators[msg.sender].balance -= RenderInvoices[_invoiceCID].jobCost;
        invoiceOperator.balance += RenderInvoices[_invoiceCID].jobCost;

        // Update the render invoice state
        RenderInvoices[_invoiceCID].state = _invoiceState;

        // Update the render job owner's statistics
        operators[msg.sender].acceptedRenderInvoices++;

        // Update the render node's render job statistics
        invoiceNode.acceptedRenderInvoices++;

    }


    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    //  CONTRACT MANAGEMENT
    // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    // TODO: Such an option adds a level of security, but also one of centralized control over the contract. 
    //       Should we give up this option in favor of absolute decentralization?
    // functions to enable the pausing and unpausing of the smart contract (in case of a contract redeployment, a bug, or an exploit)
    function pause() 
        public 
        onlyOwner 
    {
        _pause();
    }
    function unpause() 
        public 
        onlyOwner 
    {
        _unpause();
    }
    
    // function to check the contracts HBAR balance
    function getBalance() 
        public 
        view 
        onlyOwner 
        
        returns (uint256) 
    {
        return address(this).balance;
    }

}