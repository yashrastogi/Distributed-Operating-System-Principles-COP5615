// Example client to connect to the reddit_engine
// This shows how to connect and send messages using named subjects

import gleam/erlang/charlist
import gleam/erlang/process
import gleam/io
import reddit_engine

pub fn main() {
  io.println("=== Reddit Engine Client ===")

  // 1. Start this node with distribution
  reddit_engine.net_kernel_start(charlist.from_string("client"))
  reddit_engine.set_cookie("client", "secret")
  io.println("✓ Client node started")

  // 2. Ping the server to establish connection
  io.println("\n--- Connecting to server ---")
  let server_node = "reddit_engine@Yashs-MacBook-Air.local"

  let ping_result = reddit_engine.ping_erlang(charlist.from_string(server_node))
  case ping_result {
    reddit_engine.Pong ->
      io.println("✓ Successfully connected to " <> server_node)
    reddit_engine.Pang -> {
      io.println("✗ Failed to connect to " <> server_node)
      io.println("Make sure the server is running!")
    }
  }

  // Small delay to let nodes sync
  process.sleep(2000)

  // 3. List all connected nodes
  io.println("\n--- Connected Nodes ---")
  echo reddit_engine.list_nodes()

  // 4. List all globally registered names
  io.println("\n--- Global Registry ---")
  echo reddit_engine.list_global_names()

  // 5. Send messages using named subjects
  io.println("\n--- Sending Messages to Named Subject ---")

  // Send to the named subject on the remote node
  io.println("\n--- Finding Reddit Engine ---")
  case reddit_engine.whereis_global("reddit_engine") {
    Ok(engine_pid) -> {
      io.println("✓ Found reddit_engine globally!")

      // 6. Send some test messages
      io.println("\n--- Sending Messages ---")
      reddit_engine.send_to_named_subject(
        engine_pid,
        "reddit_engine",
        reddit_engine.UserRegister(username: "alice"),
      )
      io.println("✓ Sent: UserRegister(alice)")
    }

    Error(msg) -> {
      io.println("✗ " <> msg)
      io.println("\nTroubleshooting:")
      io.println("1. Is the reddit_engine server running?")
      io.println("2. Are both nodes using the same cookie ('secret')?")
      io.println("3. Did the ping succeed?")
      io.println("4. Wait a few seconds for global registry to sync")
    }
  }

  // reddit_engine.send_to_named_subject(
  //   server_node,
  //   "reddit_engine",
  //   reddit_engine.CreateSubreddit(
  //     name: "gleam",
  //     description: "Gleam programming language",
  //   ),
  // )
  // io.println("✓ Sent: CreateSubreddit(gleam)")

  // reddit_engine.send_to_named_subject(
  //   server_node,
  //   "reddit_engine",
  //   reddit_engine.JoinSubreddit(username: "alice", subreddit_name: "gleam"),
  // )
  // io.println("✓ Sent: JoinSubreddit(alice, gleam)")

  // reddit_engine.send_to_named_subject(
  //   server_node,
  //   "reddit_engine",
  //   reddit_engine.CreatePost(
  //     username: "alice",
  //     subreddit_id: "gleam",
  //     content: "Hello from distributed Gleam!",
  //     title: "First Post",
  //   ),
  // )
  // io.println("✓ Sent: CreatePost")

  io.println("\n✓ All messages sent successfully!")
}
