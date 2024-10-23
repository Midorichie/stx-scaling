# File: src/stacks_scaling/models/transaction.py
from dataclasses import dataclass
from typing import List, Dict, Optional
from enum import Enum
import time

class ChannelStatus(Enum):
    OPEN = "open"
    CLOSING = "closing"
    DISPUTE = "dispute"
    CLOSED = "closed"

@dataclass
class Transaction:
    sender: str
    recipient: str
    amount: int
    timestamp: float
    signature: str
    nonce: int
    batch_id: Optional[str] = None
    metadata: Optional[Dict] = None

@dataclass
class ChannelState:
    channel_id: str
    participants: List[str]
    balances: Dict[str, int]
    nonce: int
    status: ChannelStatus
    dispute_timeout: int = 86400  # 24 hours in seconds
    last_update: float = time.time()

# File: src/stacks_scaling/utils/crypto.py
from typing import Tuple, Optional
import hashlib
import secrets
from secp256k1 import PrivateKey, PublicKey

class CryptoManager:
    def __init__(self):
        self.private_key = PrivateKey()
        self.public_key = self.private_key.pubkey

    def create_signature(self, message: str) -> Tuple[str, str]:
        """Create a signature using secp256k1"""
        message_hash = hashlib.sha256(message.encode()).digest()
        signature = self.private_key.ecdsa_sign(message_hash)
        signature_der = self.private_key.ecdsa_serialize(signature)
        return signature_der.hex(), self.public_key.serialize().hex()

    @staticmethod
    def verify_signature(message: str, signature_hex: str, public_key_hex: str) -> bool:
        """Verify a signature using secp256k1"""
        try:
            message_hash = hashlib.sha256(message.encode()).digest()
            pubkey = PublicKey(bytes.fromhex(public_key_hex), raw=True)
            signature = bytes.fromhex(signature_hex)
            return pubkey.ecdsa_verify(message_hash, pubkey.ecdsa_deserialize(signature))
        except Exception:
            return False

# File: src/stacks_scaling/stacks_integration.py
import json
from typing import Dict, Any
import requests

class StacksInterface:
    def __init__(self, node_url: str, contract_address: str):
        self.node_url = node_url
        self.contract_address = contract_address

    def submit_channel_state(self, final_state: Dict[str, Any]) -> str:
        """Submit channel state to Stacks blockchain"""
        # In production, this would use actual Stacks blockchain API
        endpoint = f"{self.node_url}/v2/transactions"
        payload = {
            "contract_address": self.contract_address,
            "function_name": "submit_channel_state",
            "function_args": [json.dumps(final_state)]
        }
        response = requests.post(endpoint, json=payload)
        return response.json().get("txid", "")

    def verify_channel_state(self, channel_id: str) -> Dict[str, Any]:
        """Verify channel state on Stacks blockchain"""
        endpoint = f"{self.node_url}/v2/contracts/call-read/{self.contract_address}/get_channel_state"
        params = {"channel_id": channel_id}
        response = requests.get(endpoint, params=params)
        return response.json()

# File: src/stacks_scaling/payment_channel.py
from typing import List, Dict, Optional, Set
from .models.transaction import Transaction, ChannelState, ChannelStatus
from .utils.crypto import CryptoManager
from .stacks_integration import StacksInterface
import time

class BatchProcessor:
    def __init__(self):
        self.batches: Dict[str, List[Transaction]] = {}
        self.batch_thresholds = {
            "size": 100,  # Max transactions per batch
            "time": 60    # Max seconds before processing
        }

    def add_transaction(self, transaction: Transaction) -> str:
        batch_id = str(int(time.time()))
        if batch_id not in self.batches:
            self.batches[batch_id] = []
        self.batches[batch_id].append(transaction)
        transaction.batch_id = batch_id
        return batch_id

    def should_process_batch(self, batch_id: str) -> bool:
        if batch_id not in self.batches:
            return False
        batch = self.batches[batch_id]
        batch_age = time.time() - float(batch_id)
        return (len(batch) >= self.batch_thresholds["size"] or 
                batch_age >= self.batch_thresholds["time"])

class EnhancedPaymentChannel:
    def __init__(self, 
                 channel_id: str, 
                 participants: List[str], 
                 initial_balances: Dict[str, int],
                 stacks_node_url: str,
                 contract_address: str):
        self.state = ChannelState(
            channel_id=channel_id,
            participants=participants,
            balances=initial_balances,
            nonce=0,
            status=ChannelStatus.OPEN
        )
        self.pending_transactions: List[Transaction] = []
        self.settled_transactions: List[Transaction] = []
        self.crypto = CryptoManager()
        self.stacks = StacksInterface(stacks_node_url, contract_address)
        self.batch_processor = BatchProcessor()
        self.participant_signatures: Dict[str, Set[str]] = {p: set() for p in participants}

    def create_transaction(self, sender: str, recipient: str, amount: int) -> Optional[Transaction]:
        if self.state.status != ChannelStatus.OPEN:
            raise ValueError(f"Channel is {self.state.status.value}")
        
        if sender not in self.state.participants or recipient not in self.state.participants:
            raise ValueError("Invalid participants")
        
        if self.state.balances[sender] < amount:
            raise ValueError("Insufficient balance")

        message = f"{sender}{recipient}{amount}{self.state.nonce}"
        signature, public_key = self.crypto.create_signature(message)

        transaction = Transaction(
            sender=sender,
            recipient=recipient,
            amount=amount,
            timestamp=time.time(),
            signature=signature,
            nonce=self.state.nonce
        )

        batch_id = self.batch_processor.add_transaction(transaction)
        
        if self.batch_processor.should_process_batch(batch_id):
            self._process_batch(batch_id)
        
        return transaction

    def _process_batch(self, batch_id: str) -> bool:
        """Process a batch of transactions"""
        if batch_id not in self.batch_processor.batches:
            return False

        batch = self.batch_processor.batches[batch_id]
        successful_transactions = []

        for transaction in batch:
            if self._verify_and_apply_transaction(transaction):
                successful_transactions.append(transaction)

        if successful_transactions:
            self.settled_transactions.extend(successful_transactions)
            self.state.nonce += 1
            self.state.last_update = time.time()

        del self.batch_processor.batches[batch_id]
        return True

    def _verify_and_apply_transaction(self, transaction: Transaction) -> bool:
        """Verify and apply a single transaction"""
        message = f"{transaction.sender}{transaction.recipient}{transaction.amount}{transaction.nonce}"
        if not self.crypto.verify_signature(message, transaction.signature, 
                                          self.crypto.public_key.serialize().hex()):
            return False

        self.state.balances[transaction.sender] -= transaction.amount
        self.state.balances[transaction.recipient] += transaction.amount
        return True

    def initiate_dispute(self, participant: str) -> bool:
        """Initiate a dispute for the channel"""
        if participant not in self.state.participants:
            return False

        if self.state.status != ChannelStatus.OPEN:
            return False

        self.state.status = ChannelStatus.DISPUTE
        self.state.last_update = time.time()
        
        # Submit current state to Stacks blockchain
        dispute_state = self.get_channel_state()
        tx_id = self.stacks.submit_channel_state(dispute_state)
        
        return bool(tx_id)

    def resolve_dispute(self) -> bool:
        """Resolve a dispute after timeout period"""
        if self.state.status != ChannelStatus.DISPUTE:
            return False

        if time.time() - self.state.last_update < self.state.dispute_timeout:
            return False

        # Verify state on Stacks blockchain
        chain_state = self.stacks.verify_channel_state(self.state.channel_id)
        
        # Update local state if necessary
        if chain_state["nonce"] > self.state.nonce:
            self._update_state_from_chain(chain_state)

        self.state.status = ChannelStatus.CLOSED
        return True

    def _update_state_from_chain(self, chain_state: Dict) -> None:
        """Update local state from blockchain state"""
        self.state.balances = chain_state["balances"]
        self.state.nonce = chain_state["nonce"]
        self.state.last_update = chain_state["timestamp"]

    def close_channel(self) -> Dict:
        """Close the channel and settle on Stacks blockchain"""
        if self.state.status not in {ChannelStatus.OPEN, ChannelStatus.DISPUTE}:
            raise ValueError(f"Cannot close channel in {self.state.status.value} state")

        # Process any remaining batches
        for batch_id in list(self.batch_processor.batches.keys()):
            self._process_batch(batch_id)

        self.state.status = ChannelStatus.CLOSING
        
        final_state = {
            "channel_id": self.state.channel_id,
            "final_balances": self.state.balances,
            "total_transactions": len(self.settled_transactions),
            "final_nonce": self.state.nonce,
            "timestamp": time.time(),
            "status": self.state.status.value
        }

        # Submit final state to Stacks blockchain
        tx_id = self.stacks.submit_channel_state(final_state)
        if tx_id:
            self.state.status = ChannelStatus.CLOSED

        return final_state

    def get_channel_state(self) -> Dict:
        return {
            "channel_id": self.state.channel_id,
            "status": self.state.status.value,
            "current_balances": self.state.balances,
            "pending_batches": len(self.batch_processor.batches),
            "settled_transactions": len(self.settled_transactions),
            "current_nonce": self.state.nonce,
            "last_update": self.state.last_update
        }