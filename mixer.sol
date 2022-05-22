// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

contract Mixer {

    enum Role {
        Participant,
        Banker,
        Blacklisted
    } // bankers get the same priviledges as participcants

    enum MaskedCDStatus {
        NotSubmitted,
        Unsigned,
        Signed
    }

    struct RSAPublicKey {
        uint128 e; // public exponent
        uint128 n; // modulus
    }

    struct AccountDetails {
        Role role;
        uint256 balance;
        uint256 bankerID; // index in bankers array. Only bankers have this
        RSAPublicKey bankerPK;
        uint128 lastMaskedCD; // last maskedCD deposited by this account
        // ? uint lastRequestCycle
    }

    struct Cycle {
        address banker; // current banker
        RSAPublicKey pk;
        bool bankerCheated;

        uint256 initBlock;
        uint256 depositDeadline;
        uint256 requestDeadline;

        address[] depositors;
        address[] claimants;
        address[] intermediaries;

        mapping(uint128 => MaskedCDDetails) maskedCDDetails;
        mapping(uint128 => ClaimedCDDetails) claimedCDDetails; // has CD been claimed
    }

    struct MaskedCDDetails {
        MaskedCDStatus status;
        uint256 cycleEnd; // * Cycle End blocks are used as unique identifiers for each cycle
        address depositor; 
        uint128 signed;
    }

    struct ClaimedCDDetails {
        uint256 cycleEnd; // * Cycle End blocks are used as unique identifiers for each cycle
        address claimant;
    }

    address[] public bankers;
    mapping(address => AccountDetails) accountDetails;
    Cycle public cycle;

    uint256 public signingFee = 0.1 ether;
    uint256 public claimFee = 0.1 ether;
    uint256 public transferFee = 0.1 ether;
    uint256 public bankerDeposit = 10 ether;
    uint64 public maxDeposits = 50;

    event newCycleEvent(
        address newBanker,
        uint256 cycleInitBlock,
        uint256 cycleDepositDeadline,
        uint256 cycleRequestDeadline
    );

    event depositEvent(
        address depositor, 
        uint128 maskedCD
    );
    
    event signatureEvent(
        uint128 maskedCD,
        uint128 signedMaskedCD 
    );
    
    event requestEvent(
        address claimant,
        address intermediary,
        uint128 signedCD 
    );

    event blacklistEvent(address cheater);

    constructor(RSAPublicKey memory bankerPK) payable {
        registerAsBanker(bankerPK);
        _resetCycle();
    }

    modifier bankersOnly() {
        require(accountDetails[msg.sender].role == Role.Banker,"You are not a banker");
        _;
    }

    modifier allParticipants() {
        require(accountDetails[msg.sender].role != Role.Blacklisted, "You are Blacklisted");
        _;
    }

    function resetCycle() external allParticipants{
        require((block.number > cycle.requestDeadline)||(block.number > cycle.depositDeadline && cycle.depositors.length==0), "Cycle cannot be reset");
        if (block.number <= cycle.requestDeadline) _deregisterBanker(cycle.banker);
        _resetCycle();
    }

    function _resetCycle() internal {
        require(bankers.length>0, "Awaiting bankers");

        // distribute last cycle's deposits
        if (!cycle.bankerCheated) {
            for (uint16 d = 0; d < cycle.depositors.length; d++) {
                accountDetails[cycle.depositors[d]].balance -= 1 ether;
                if (d < cycle.claimants.length) {
                    accountDetails[cycle.claimants[d]].balance += 1 ether - claimFee;
                    accountDetails[cycle.intermediaries[d]].balance += claimFee;
                }
            }
        }

        delete cycle.depositors;
        delete cycle.claimants;

        // new deadlines
        cycle.initBlock = block.number;
        uint256 day = (24 * 60 * 60) / uint256(13);
        cycle.depositDeadline = cycle.initBlock + day;
        cycle.requestDeadline = cycle.depositDeadline + day;

        // new banker
        uint256 currentBankerID = accountDetails[cycle.banker].bankerID;
        cycle.banker = bankers[(currentBankerID + 1) % bankers.length];
        cycle.pk.e = accountDetails[cycle.banker].bankerPK.e;
        cycle.pk.n = accountDetails[cycle.banker].bankerPK.n;
        cycle.bankerCheated = false;

        emit newCycleEvent(
            cycle.banker,
            cycle.initBlock,
            cycle.depositDeadline,
            cycle.requestDeadline
        );
    }

    function getBankerPK() public view returns (RSAPublicKey memory){
        return cycle.pk;
    }

    function registerAsBanker(RSAPublicKey memory pk) public payable {
        require(
            accountDetails[msg.sender].role == Role.Participant,
            "You are either already a banker or you are blacklisted"
        );
        require(msg.value >= bankerDeposit);
        
        accountDetails[msg.sender].bankerID = bankers.length;
        bankers.push(msg.sender);
        accountDetails[msg.sender].role = Role.Banker;
        accountDetails[msg.sender].bankerPK = pk;
    }

    function deregisterAsBanker() external bankersOnly{
        require(cycle.banker!=msg.sender, "current banker cannot deregister");
        _deregisterBanker(msg.sender);
    }

    function _deregisterBanker(address banker) internal{

        uint256 bankerID = accountDetails[banker].bankerID;
        
        // remove banker from bankers
        accountDetails[banker].role = Role.Participant;
        bankers[bankerID] = bankers[bankers.length - 1]; 
        bankers.pop();

        // re-assign bankerID
        delete accountDetails[banker].bankerID;
        accountDetails[bankers[bankerID]].bankerID = bankerID; 

        // return deposit
        accountDetails[banker].balance += bankerDeposit;

        delete accountDetails[banker].bankerPK;
    }

    function updateKey(RSAPublicKey memory pk) external bankersOnly {
        accountDetails[msg.sender].bankerPK = pk;
    }

    function blacklist(address cheater) private {
        require(accountDetails[cheater].role != Role.Blacklisted);

        if (accountDetails[cheater].role == Role.Banker) {
            uint256 bankerID = accountDetails[cheater].bankerID;
            bankers[bankerID] = bankers[bankers.length - 1]; // remove cheater from bankers
            bankers.pop();
            accountDetails[bankers[bankerID]].bankerID = bankerID; // re-assign bankerID
        }
        accountDetails[cheater].role = Role.Blacklisted;
        delete accountDetails[cheater].balance;
        emit blacklistEvent(cheater);
    }

    function verifySignature(
        uint128 message, // sha256 hashed message % n
        uint128 sign, // message**d % n
        RSAPublicKey memory pk
    ) internal pure returns (bool) {
        
        uint n = uint(pk.n);
        uint exp = uint(pk.e);
        uint base = uint(sign) % n;
        uint unsignedMessage = 1;

        while (exp > 0){
            if ((exp & 1) > 0) unsignedMessage = (unsignedMessage * base) % n;
            exp >>= 1;
            base = (base**2) % n;
        }

        return (unsignedMessage == uint(message));
    }

    function depositEther(uint128 maskedCD) external payable allParticipants {
        require(
            block.number <= cycle.depositDeadline,
            "Not in the deposit phase. Please try during next cycle or request to reset cycle."
        );

        require(
            msg.value >= (1 ether + signingFee),
            "Please submit at least 1.1 ether"
        );

        require(cycle.maskedCDDetails[accountDetails[msg.sender].lastMaskedCD].cycleEnd != cycle.requestDeadline, "You have already made a deposit in this cycle");

        // If same maskedCD has not been used this cycle, then initialize it, else revert
        if (cycle.maskedCDDetails[maskedCD].cycleEnd != cycle.requestDeadline)
            cycle.maskedCDDetails[maskedCD] = MaskedCDDetails(
                MaskedCDStatus.Unsigned,
                cycle.requestDeadline,
                msg.sender,
                0
            );
        else
            revert(
                "A maskedCD with the same value has already been submitted in this cycle"
            );

        accountDetails[msg.sender].balance += 1 ether + signingFee; // * refundable until signed
        accountDetails[msg.sender].lastMaskedCD = maskedCD;

        emit depositEvent(msg.sender, maskedCD);
    }

    function signMaskedCD(uint128 maskedCD, uint128 sign) external bankersOnly {
        require(
            block.number <= cycle.depositDeadline,
            "Not in the deposit phase. Please try during next cycle or request to reset cycle."
        );

        require(
            cycle.banker == msg.sender,
            "You are not the banker for this cycle"
        );
        require(
            cycle.maskedCDDetails[maskedCD].cycleEnd == cycle.requestDeadline &&
                cycle.maskedCDDetails[maskedCD].status ==
                MaskedCDStatus.Unsigned,
            "Invalid Unsigned MaskedCD"
        );

        require(verifySignature(maskedCD, sign, cycle.pk), "Signature mismatch");

        require(
            cycle.depositors.length <= maxDeposits,
            "Maximum number of deposits for this cycle have been signed"
        );

        cycle.maskedCDDetails[maskedCD].signed = sign;
        cycle.maskedCDDetails[maskedCD].status = MaskedCDStatus.Signed;
        address depositor = cycle.maskedCDDetails[maskedCD].depositor;
        cycle.depositors.push(depositor);

        // pay banker signing fees
        accountDetails[depositor].balance -= signingFee;
        accountDetails[cycle.banker].balance += signingFee;

        emit signatureEvent(maskedCD, sign);
    }

    function bankerCheated() internal {
        // Blacklist Banker
        cycle.bankerCheated = true;

        // distribute all of the banker's money.
        uint256 compensation = (bankerDeposit +
            accountDetails[cycle.banker].balance) /
            cycle.depositors.length;
        for (uint16 d = 0; d < cycle.depositors.length; d++)
            accountDetails[cycle.depositors[d]].balance += compensation;

        // resetCycle
        blacklist(cycle.banker);
        _resetCycle();
        // ! old depositors can collect their money now
    }

    function requestWithdrawal(
        uint128 signedCD,
        uint nonce,
        address claimant
    ) external allParticipants {
        require(
            block.number <= cycle.requestDeadline,
            "Deadline to request withdrawal has passed."
        );
        require(
            block.number > cycle.depositDeadline,
            "Still in the deposit phase"
        );

        require(cycle.claimants.length <= cycle.depositors.length);

        RSAPublicKey memory bankerPK = cycle.pk;
        uint128 CD = uint128(uint256(sha256(abi.encodePacked(cycle.requestDeadline, nonce, claimant)))) % bankerPK.n;
        require(
            verifySignature(
                CD,
                signedCD,
                bankerPK
            ),
            "Signature mismatch"
        );

        if (cycle.claimedCDDetails[signedCD].cycleEnd != cycle.requestDeadline)
            cycle.claimedCDDetails[signedCD] = ClaimedCDDetails(
                cycle.requestDeadline,
                claimant
            );
        else revert("This signedCD has already been claimed");

        cycle.claimants.push(claimant);
        cycle.intermediaries.push(msg.sender);

        emit requestEvent(claimant, msg.sender, signedCD);

        if (cycle.claimants.length > cycle.depositors.length) bankerCheated();
    }

    function transferMoney(address payee) external allParticipants {
        require(accountDetails[payee].balance > 0);
        require(accountDetails[payee].role != Role.Blacklisted);
        require(
            payee != cycle.banker,
            "Bankers cannot withdraw during their cycle"
        );

        // Prevent depositors from getting a refund after getting their MaskedCD signed
        // if made deposit this cycle and withdrew, then re-initialize maskedCDDetails
        MaskedCDDetails memory lastMaskedCDDetails = cycle.maskedCDDetails[accountDetails[payee].lastMaskedCD];
        if (lastMaskedCDDetails.cycleEnd == cycle.requestDeadline) {
            require(
                lastMaskedCDDetails.status != MaskedCDStatus.Signed,
                "Accounts with signed maskedCDs cannot withdraw in the same cycle"
            );
            if (lastMaskedCDDetails.status == MaskedCDStatus.Unsigned)
                delete cycle.maskedCDDetails[accountDetails[payee].lastMaskedCD];
        }

        // Pay Intermediary (balance, not actual transfer). check if payee can afford fees
        if (payee!=msg.sender) {
            require(accountDetails[payee].balance > transferFee);
            accountDetails[payee].balance -= transferFee;
            accountDetails[msg.sender].balance += transferFee;
        }


        uint amount = accountDetails[payee].balance;
        accountDetails[payee].balance = 0;
        (bool sent, ) = payable(payee).call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
}
