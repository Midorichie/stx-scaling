# Initialize channel with Stacks network details
channel = EnhancedPaymentChannel(
    channel_id="channel_001",
    participants=["alice", "bob"],
    initial_balances={"alice": 1000, "bob": 1000},
    stacks_node_url="https://stacks-node-api.mainnet.stacks.co",
    contract_address="ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM"
)

# Create transactions (they'll be automatically batched)
tx1 = channel.create_transaction("alice", "bob", 100)
tx2 = channel.create_transaction("bob", "alice", 50)

# Check channel state
state = channel.get_channel_state()
print(state)

# Handle disputes if needed
if dispute_detected:
    channel.initiate_dispute("alice")
    # Wait for dispute timeout
    channel.resolve_dispute()

# Close channel
final_state = channel.close_channel()