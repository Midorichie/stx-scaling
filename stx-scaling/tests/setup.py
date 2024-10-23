# Initialize a payment channel
channel = PaymentChannel(
    channel_id="channel_001",
    participants=["alice", "bob"],
    initial_balances={"alice": 1000, "bob": 1000}
)

# Create and process transactions
tx1 = channel.create_transaction("alice", "bob", 100)
channel.process_transaction(tx1)

# Get channel state
state = channel.get_channel_state()
print(state)

# Close channel
final_state = channel.close_channel()
stacks_tx = create_mock_stacks_transaction(final_state)