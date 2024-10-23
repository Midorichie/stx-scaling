import hashlib
import time
from typing import List, Dict, Optional
from dataclasses import dataclass
import json

@dataclass
class Transaction:
    sender: str
    recipient: str
    amount: int
    timestamp: float
    signature: str
    nonce: int

@dataclass
class ChannelState:
    channel_id: str
    participants: List[str]
    balances: Dict[str, int]
    nonce: int
    is_open: bool

class PaymentChannel:
    def __init__(self, channel_id: str, participants: List[str], initial_balances: Dict[str, int]):
        self.state = ChannelState(
            channel_id=channel_id,
            participants=participants,
            balances=initial_balances,
            nonce=0,
            is_open=True
        )
        self.pending_transactions: List[Transaction] = []
        self.settled_transactions: List[Transaction] = []

    def create_transaction(self, sender: str, recipient: str, amount: int) -> Optional[Transaction]:
        """Create an off-chain transaction within the payment channel."""
        if not self.state.is_open:
            raise ValueError("Channel is closed")
        
        if sender not in self.state.participants or recipient not in self.state.participants:
            raise ValueError("Invalid participants")
        
        if self.state.balances[sender] < amount:
            raise ValueError("Insufficient balance")

        # Create transaction
        transaction = Transaction(
            sender=sender,
            recipient=recipient,
            amount=amount,
            timestamp=time.time(),
            signature=self._sign_transaction(sender, recipient, amount),
            nonce=self.state.nonce
        )

        self.pending_transactions.append(transaction)
        return transaction

    def _sign_transaction(self, sender: str, recipient: str, amount: int) -> str:
        """Sign a transaction using a simple hash (in production, use proper cryptographic signatures)"""
        message = f"{sender}{recipient}{amount}{self.state.nonce}"
        return hashlib.sha256(message.encode()).hexdigest()

    def verify_transaction(self, transaction: Transaction) -> bool:
        """Verify transaction signature and validity."""
        expected_signature = self._sign_transaction(
            transaction.sender,
            transaction.recipient,
            transaction.amount
        )
        return transaction.signature == expected_signature

    def process_transaction(self, transaction: Transaction) -> bool:
        """Process a pending transaction and update channel state."""
        if not self.verify_transaction(transaction):
            return False

        # Update balances
        self.state.balances[transaction.sender] -= transaction.amount
        self.state.balances[transaction.recipient] += transaction.amount
        self.state.nonce += 1

        # Move transaction from pending to settled
        self.pending_transactions.remove(transaction)
        self.settled_transactions.append(transaction)
        return True

    def close_channel(self) -> Dict:
        """Close the payment channel and prepare final state for on-chain settlement."""
        self.state.is_open = False
        
        # Process any remaining pending transactions
        for transaction in self.pending_transactions[:]:
            self.process_transaction(transaction)

        # Prepare final state for on-chain settlement
        final_state = {
            "channel_id": self.state.channel_id,
            "final_balances": self.state.balances,
            "total_transactions": len(self.settled_transactions),
            "final_nonce": self.state.nonce,
            "timestamp": time.time()
        }
        return final_state

    def get_channel_state(self) -> Dict:
        """Get current channel state and metrics."""
        return {
            "channel_id": self.state.channel_id,
            "is_open": self.state.is_open,
            "current_balances": self.state.balances,
            "pending_transactions": len(self.pending_transactions),
            "settled_transactions": len(self.settled_transactions),
            "current_nonce": self.state.nonce
        }

def create_mock_stacks_transaction(channel_state: Dict) -> str:
    """
    Simulate creating a Stacks transaction for channel settlement
    In production, this would interact with the Stacks blockchain
    """
    return hashlib.sha256(json.dumps(channel_state).encode()).hexdigest()