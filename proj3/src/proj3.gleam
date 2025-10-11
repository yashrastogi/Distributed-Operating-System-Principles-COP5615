/// Chord DHT implemented using OTP-style actors (gleam/otp/actor).
/// This file wires up a set of Chord nodes, starts periodic
/// stabilization and finger-fixing actors, and contains the
/// node handler and helper functions for the Chord protocol.
import argv
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile.{read as read_file}

// ---------------------------------------------------------------------------
// Constants — timeouts and sleeps (milliseconds)
// ---------------------------------------------------------------------------

const long_wait_time = 2000

const medium_wait_time = 50

const short_wait_time = 50

const finger_list_size = 160

/// How long the main thread sleeps after starting background actors.
/// This lets the periodic actors run for a while before the program ends.
const main_thread_sleep = 8000

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  // Parse command line arguments: num_nodes and num_requests
  let #(num_nodes, num_requests) = parse_args()

  // Create all node actors and an initial routing table
  let #(sub_tups, _routing_table) = create_actors(num_nodes, num_requests)

  // Start a background actor that periodically calls stabilize on nodes
  let assert Ok(stabilize_actor) =
    actor.new_with_initialiser(long_wait_time, fn(self_sub: Subject(Int)) {
      #(self_sub, sub_tups)
      |> actor.initialised
      |> actor.returning(self_sub)
      |> Ok
    })
    |> actor.on_message(run_periodic_stabilize)
    |> actor.start
  actor.send(stabilize_actor.data, 1)

  // Start a background actor that periodically calls fix_fingers on nodes
  let assert Ok(fix_fingers_actor) =
    actor.new_with_initialiser(long_wait_time, fn(self_sub: Subject(Int)) {
      #(self_sub, sub_tups)
      |> actor.initialised
      |> actor.returning(self_sub)
      |> Ok
    })
    |> actor.on_message(run_periodic_fix_fingers)
    |> actor.start
  actor.send(fix_fingers_actor.data, 1)

  // Keep the main thread alive so background actors continue running
  process.sleep(main_thread_sleep)
  actor.send(stabilize_actor.data, 0)
  actor.send(fix_fingers_actor.data, 0)
  process.sleep(4000)
  let assert Ok(first) = sub_tups |> list.first
  let assert Ok(f) = read_file("./src/sentences.txt")
  let sentences =
    f
    |> string.split("\n")

  sentences
  |> list.each(fn(line) {
    actor.send(first.0, Put(line))
    process.sleep(10)
  })

  io.println("\n=== Initiating numRequests from each node ===")
  list.index_map(sub_tups, fn(tup, i) {
    io.println("")
    list.sample(sentences, num_requests)
    |> list.each(fn(sentence) {
      io.println(
        "Searching data "
        <> hash_data(sentence)
        <> " from node "
        <> int.to_string(i)
        <> " found at "
        <> actor.call(
          tup.0,
          sending: fn(r) { Get(hash_data(sentence), r, 0) },
          waiting: long_wait_time,
        ).0,
      )
      process.sleep(100)
    })
  })

  process.sleep(long_wait_time)

  // After stabilization, print successor and predecessor of each node
  io.println("\n=== Final successor/predecessor list ===")
  list.each(sub_tups, fn(tup) { actor.send(tup.0, PrintSuccPred) })
  process.sleep(2000)

  Nil
}

// ---------------------------------------------------------------------------
// Helper to assign the routing table to a node actor (synchronous call)
// ---------------------------------------------------------------------------

/// A helper function to assign routing table to an actor. Uses a synchronous
/// `actor.call` so the caller knows when the target actor has stored it.
fn assign_routing_table(
  subject: Subject(ChordNodeMessage),
  routing_table: Dict(String, #(Subject(ChordNodeMessage), Pid)),
) {
  actor.call(
    subject,
    sending: fn(reply_box) { StoreRoutingTable(routing_table, reply_box) },
    waiting: long_wait_time,
  )
}

// ---------------------------------------------------------------------------
// Actor creation & bootstrap
// ---------------------------------------------------------------------------

/// Create the given number of node actors, initialize their states,
/// and wire up an initial routing table. Returns:
///   - a list of tuples (node_subject, node_pid)
///   - a routing table map keyed by node_id -> (subject, pid)
fn create_actors(
  num_nodes: Int,
  num_requests: Int,
) -> #(
  List(#(Subject(ChordNodeMessage), process.Pid)),
  Dict(String, #(Subject(ChordNodeMessage), process.Pid)),
) {
  // Build a list of mappings (node_id_hash, #(subject, pid))
  let mapping_list =
    list.range(1, num_nodes)
    |> list.map(fn(index) {
      // Derive a node id hash
      let index_hash = hash_node(index)

      // Create an actor with an initializer that returns its initial state
      let assert Ok(n_actor) =
        actor.new_with_initialiser(long_wait_time, fn(self_sub) {
          // Initial node state for the Chord node
          ChordNodeState(
            routing_table: dict.new(),
            actor_index: index,
            node_id: index_hash,
            self_subject: self_sub,
            node_data: dict.new(),
            num_requests: num_requests,
            successor_id: index_hash,
            successor_list: [],
            finger_list: dict.new(),
            predecessor_id: "",
            fix_finger_number: 1,
          )
          |> actor.initialised
          |> actor.returning(self_sub)
          |> Ok
        })
        |> actor.on_message(chord_node_handler)
        |> actor.start

      // Return a mapping tuple with the node hash and the actor data/pid
      #(index_hash, #(n_actor.data, n_actor.pid))
    })

  // Build the list of subject/pid tuples (for compatibility with existing code)
  // sub_tups is a list of #(Subject(ChordNodeMessage), Pid)
  let sub_tups = list.map(mapping_list, fn(tup) { #(tup.1.0, tup.1.1) })

  // Propagate the complete routing table to everyone for now
  let routing_table = dict.from_list(mapping_list)
  list.each(sub_tups, fn(tup) { assign_routing_table(tup.0, routing_table) })

  // Ask all nodes to join the network via the first node
  let assert Ok(first_mapping) = list.first(mapping_list)
  list.each(sub_tups, fn(tup) { actor.send(tup.0, Join(first_mapping.0)) })

  // Return the node subjects/pids and the routing table
  #(sub_tups, routing_table)
}

// ---------------------------------------------------------------------------
// Primary actor message handler for each Chord node
// ---------------------------------------------------------------------------

pub fn chord_node_handler(
  state: ChordNodeState,
  message: ChordNodeMessage,
) -> actor.Next(ChordNodeState, ChordNodeMessage) {
  case message {
    UpdateNodeData(data:) -> {
      // Merge incoming data into node_data. On key clash, keep existing value.
      let new_state =
        ChordNodeState(
          ..state,
          node_data: dict.combine(state.node_data, data, fn(clash1, _) {
            clash1
          }),
        )
      actor.continue(new_state)
    }

    GetPredecessor(reply_to) -> {
      // Return the predecessor id
      actor.send(reply_to, GotPredecessorReply(state.predecessor_id))
      actor.continue(state)
    }

    FindSuccessor(id, reply_to) -> {
      // Lookup the successor for the given id and reply with it
      // echo "Running find_successor on node "
      //   <> state.node_id |> string.slice(0, 6)
      actor.send(reply_to, find_successor(id, state))
      actor.continue(state)
    }

    FixFingers -> {
      // Fix the finger table entry indexed by state.fix_finger_number
      let max_nodes = int_power(2, 160)

      // Convert node id to integer and compute finger target
      let assert Ok(node_id_int) = int.base_parse(state.node_id, 16)
      let finger_id_int =
        { node_id_int + int_power(2, state.fix_finger_number - 1) } % max_nodes
      let finger_id = int.to_base16(finger_id_int)

      // Find successor for the computed finger id
      let finger_id_successor_id = find_successor(finger_id, state)

      // Insert into the finger list
      let new_finger_list =
        dict.insert(
          state.finger_list,
          state.fix_finger_number,
          finger_id_successor_id.0,
        )

      // io.println(
      //   "\nFinger list for node "
      //   <> state.node_id
      //   <> ":\n["
      //   <> dict.fold(new_finger_list, "", with: fn(acc, _, val) {
      //     val <> ", " <> acc
      //   })
      //   <> " ]\n",
      // )

      // Update the fix_finger_number in a cyclic manner (1..160)
      let new_state =
        ChordNodeState(
          ..state,
          finger_list: new_finger_list,
          fix_finger_number: { state.fix_finger_number % finger_list_size } + 1,
        )
      actor.continue(new_state)
    }

    Stabilize -> actor.continue(stabilize(state))

    // ---------------------------------------------------------------------
    // Data operations
    // ---------------------------------------------------------------------
    // TODO: Replicate to r successors (currently stores to single responsible node)
    Put(data:) -> {
      echo "Put called on node "
        <> state.node_id |> string.slice(0, 6)
        <> " with data "
        <> data
      let key = hash_data(data)
      let #(successor_id, _) = find_successor(key, state)

      let new_node_data = case successor_id == state.node_id {
        // responsible: store the key locally
        True -> dict.insert(state.node_data, key, data)
        // forward to responsible node
        False -> {
          actor.send(is_alive_sub(successor_id, state).1, Put(data))
          state.node_data
        }
      }

      let new_state = ChordNodeState(..state, node_data: new_node_data)
      actor.continue(new_state)
    }

    Get(key:, reply_to:, initial_hops:) -> {
      // Retrieve a value for a key. If this node is not responsible, forward
      // echo "Get called on node "
      //   <> state.node_id |> string.slice(0, 6)
      //   <> " with key "
      //   <> key |> string.slice(0, 6)
      let #(successor_id, hops) = find_successor(key, state)
      case successor_id == state.node_id {
        False ->
          // Forward call to responsible node asynchronously
          actor.send(
            is_alive_sub(successor_id, state).1,
            Get(key, reply_to, hops),
          )

        True ->
          // Attempt to get the value locally
          actor.send(reply_to, #(
            dict.get(state.node_data, key) |> result.unwrap("NF"),
            initial_hops,
          ))
      }
      actor.continue(state)
    }

    // ---------------------------------------------------------------------
    // Joining & routing table
    // ---------------------------------------------------------------------
    Join(existing_node_id:) -> {
      // Join the network using an existing node as entry point
      echo "Join"
      case existing_node_id == state.node_id {
        True -> actor.continue(state)

        False -> {
          io.println(
            "Node "
            <> state.node_id |> string.slice(0, 6)
            <> " joining n_id: "
            <> existing_node_id |> string.slice(0, 6),
          )
          let existing_node = is_alive_sub(existing_node_id, state)

          // Ask the existing node for the successor of this node's id
          let successor_node_id =
            actor.call(
              existing_node.1,
              sending: fn(reply_box) { FindSuccessor(state.node_id, reply_box) },
              waiting: medium_wait_time,
            )

          let new_state =
            ChordNodeState(
              ..state,
              successor_id: successor_node_id.0,
              successor_list: [successor_node_id.0],
              finger_list: dict.insert(
                state.finger_list,
                1,
                successor_node_id.0,
              ),
            )

          echo "Node "
            <> state.node_id |> string.slice(0, 6)
            <> " successor is "
            <> successor_node_id.0 |> string.slice(0, 6)
          actor.continue(new_state)
        }
      }
    }

    StoreRoutingTable(routing_table:, reply_to:) -> {
      // Store the global routing table (sent at initialization)
      echo "StoreRoutingTable"
      let new_state = ChordNodeState(..state, routing_table: routing_table)
      actor.send(reply_to, True)
      actor.continue(new_state)
    }

    Notify(potential_predecessor_id:) ->
      actor.continue(notify(potential_predecessor_id, state))

    PrintSuccPred -> {
      io.println(
        "Node "
        <> state.node_id |> string.slice(0, 6)
        <> " | successor: "
        <> state.successor_id |> string.slice(0, 6)
        <> " | predecessor: "
        <> case state.predecessor_id {
          "" -> "(none)"
          p -> p |> string.slice(0, 6)
        }
        <> " | data: "
        <> state.node_data |> dict.keys |> list.length |> int.to_string,
      )
      actor.continue(state)
    }

    GotPredecessorReply(predecessor_id:) -> {
      let new_successor_id = case predecessor_id {
        "" -> state.successor_id
        _ ->
          check_predecessor_as_successor(
            predecessor_id,
            state.successor_id,
            state,
          )
      }
      // Rebuild successor list from the chosen successor
      let new_successor_list = build_successor_list(new_successor_id, state)
      // Update finger table with new successor
      let new_finger_list = dict.insert(state.finger_list, 1, new_successor_id)
      // Notify the new successor of our existence
      let successor_node = is_alive_sub(new_successor_id, state)
      actor.send(successor_node.1, Notify(state.node_id))
      // Return state with updated values
      actor.continue(
        ChordNodeState(
          ..state,
          successor_id: new_successor_id,
          successor_list: new_successor_list,
          finger_list: new_finger_list,
        ),
      )
    }
  }
}

pub fn notify(
  potential_predecessor_id: String,
  state: ChordNodeState,
) -> ChordNodeState {
  // echo "Notify on node " <> state.node_id |> string.slice(0, 6)
  // Successor notifies this node that it might be this node's predecessor.
  // Update predecessor and transfer any keys that should now belong to it.
  // If the new predecessor should take keys, copy the relevant keys
  let new_predecessor_and_data = case
    state.predecessor_id == ""
    || in_range(
      potential_predecessor_id,
      state.predecessor_id,
      state.node_id,
      False,
    )
  {
    False -> #(state.predecessor_id, state.node_data)
    True -> {
      let copied_keys =
        transfer_keys_in_range(
          potential_predecessor_id,
          state.predecessor_id,
          potential_predecessor_id,
          state.node_id,
          state.node_data,
          state,
        )

      // Drop the transferred keys locally
      let new_node_data = dict.drop(state.node_data, copied_keys)

      #(potential_predecessor_id, new_node_data)
    }
  }

  let #(new_predecessor, new_node_data) = new_predecessor_and_data

  ChordNodeState(
    ..state,
    predecessor_id: new_predecessor,
    node_data: new_node_data,
  )
}

// ---------------------------------------------------------------------------
// Chord routing helpers
// ---------------------------------------------------------------------------

pub fn find_successor(id: String, state: ChordNodeState) {
  // If id ∈ (node_id, successor] then successor is responsible
  case in_range(id, state.node_id, state.successor_id, True) {
    True -> #(state.successor_id, 0)
    False -> {
      // Otherwise, forward the request to the closest preceding node
      let closest_node_id =
        closest_preceding_node(state.finger_list, state.node_id, id)
      case closest_node_id == state.node_id {
        // No better option than this node: fallback to own successor
        True -> #(state.successor_id, 0)
        False -> {
          // Ask the chosen node to find the successor for id
          let closest_node = is_alive_sub(closest_node_id, state)
          let closest_node_successor =
            actor.call(
              closest_node.1,
              waiting: medium_wait_time,
              sending: fn(r) { FindSuccessor(id, r) },
            )
          #(closest_node_successor.0, closest_node_successor.1 + 1)
        }
      }
    }
  }
}

/// Walk the finger list from highest to lowest to find the closest
/// node that precedes `id`. If none found, return this node id.
pub fn closest_preceding_node(
  finger_list: Dict(Int, String),
  this_node_id: String,
  id: String,
) -> String {
  let finger_result =
    list.reverse(list.range(1, finger_list |> dict.keys |> list.length))
    |> list.find_map(fn(finger_number) {
      let assert Ok(finger_id) = dict.get(finger_list, finger_number)
      case in_range(finger_id, this_node_id, id, False) {
        True -> Ok(finger_id)
        False -> Error(Nil)
      }
    })

  case finger_result {
    Ok(finger_id) -> finger_id
    Error(_) -> this_node_id
  }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ChordNodeMessage {
  Stabilize
  GetPredecessor(reply_to: Subject(ChordNodeMessage))
  GotPredecessorReply(predecessor_id: String)
  FixFingers
  Put(data: String)
  Get(key: String, reply_to: Subject(#(String, Int)), initial_hops: Int)
  UpdateNodeData(data: Dict(String, String))
  Join(existing_node_id: String)
  Notify(potential_predecessor_id: String)
  FindSuccessor(id: String, reply_to: Subject(#(String, Int)))
  PrintSuccPred
  StoreRoutingTable(
    routing_table: Dict(String, #(Subject(ChordNodeMessage), Pid)),
    reply_to: Subject(Bool),
  )
}

pub type ChordNodeState {
  ChordNodeState(
    routing_table: Dict(String, #(Subject(ChordNodeMessage), Pid)),
    self_subject: Subject(ChordNodeMessage),
    actor_index: Int,
    node_id: String,
    successor_id: String,
    fix_finger_number: Int,
    predecessor_id: String,
    successor_list: List(String),
    node_data: Dict(String, String),
    finger_list: Dict(Int, String),
    num_requests: Int,
  )
}

// ---------------------------------------------------------------------------
// Data transfer helper
// ---------------------------------------------------------------------------

/// Copies keys in a given range to another node. Keys are sent but not deleted
/// here (the caller handles deletion after confirming transfer).
pub fn transfer_keys_in_range(
  to_node_id: String,
  from_id: String,
  to_id: String,
  this_node_id: String,
  this_node_data: Dict(String, String),
  state: ChordNodeState,
) -> List(String) {
  // Select keys that fall in the requested range
  let data_to_transfer =
    dict.filter(this_node_data, fn(key, _) {
      case from_id != "" {
        True -> in_range(key, from_id, to_id, True)
        False -> in_range(key, this_node_id, to_id, True)
      }
    })

  let to_node = is_alive_sub(to_node_id, state)

  // If there are keys to transfer and the target is remote, send them
  case
    to_node_id != this_node_id && dict.keys(data_to_transfer) |> list.length > 0
  {
    True -> {
      actor.send(to_node.1, UpdateNodeData(data_to_transfer))
      dict.keys(data_to_transfer)
    }
    False -> []
  }
}

// ---------------------------------------------------------------------------
// Stabilize node
// ---------------------------------------------------------------------------

pub fn stabilize(state: ChordNodeState) -> ChordNodeState {
  // Periodic stabilization: verify successor and notify it if necessary
  io.println(
    "Stabilize on actor "
    <> state.node_id |> string.slice(0, 6)
    <> " successor is "
    <> state.successor_id |> string.slice(0, 6)
    <> " predecessor is "
    <> state.predecessor_id |> string.slice(0, 6),
  )
  // Find the best available successor
  let new_successor_id = find_best_successor(state)

  actor.send(
    is_alive_sub(new_successor_id, state).1,
    GetPredecessor(state.self_subject),
  )

  ChordNodeState(
    ..state,
    successor_id: new_successor_id,
    successor_list: build_successor_list(new_successor_id, state),
    finger_list: dict.insert(state.finger_list, 1, new_successor_id),
  )
}

fn find_best_successor(state: ChordNodeState) -> String {
  let successor_alive = is_alive_sub(state.successor_id, state)
  let is_successor_invalid =
    !successor_alive.0 || state.successor_id == state.node_id

  case is_successor_invalid {
    True -> find_successor_replacement(state)
    False -> state.successor_id
  }
}

fn find_successor_replacement(state: ChordNodeState) -> String {
  // Search successor_list for a live candidate
  list.find_map(state.successor_list, fn(candidate_id) {
    case candidate_id == state.node_id {
      True -> Error(Nil)
      False ->
        case is_alive_sub(candidate_id, state).0 {
          True -> Ok(candidate_id)
          False -> Error(Nil)
        }
    }
  })
  |> result.unwrap(state.node_id)
}

fn check_predecessor_as_successor(
  predecessor_id: String,
  current_successor_id: String,
  state: ChordNodeState,
) -> String {
  let predecessor_alive = is_alive_sub(predecessor_id, state)
  let is_better_successor =
    predecessor_alive.0
    && in_range(predecessor_id, state.node_id, current_successor_id, False)

  case is_better_successor {
    True -> predecessor_id
    False -> current_successor_id
  }
}

fn build_successor_list(
  successor_id: String,
  _state: ChordNodeState,
) -> List(String) {
  // echo "hi"
  // case successor_id == state.node_id {
  //   True -> state.successor_list
  //   False -> {
  //     let successors =
  //       list.range(1, successor_list_size)
  //       |> list.map_fold(from: successor_id, with: fn(current_id, _) {
  //         echo state.node_id
  //         let next =
  //           actor.call(
  //             is_alive_sub(current_id, state).1,
  //             waiting: medium_wait_time,
  //             sending: fn(r) {
  //               echo current_id
  //               FindSuccessor(successor_id, r)
  //             },
  //           )

  //         #(next.0, next.0)
  //       })
  //     echo "hi2"
  //     [successor_id, ..successors.1]
  //   }
  // }
  [successor_id]
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

pub fn parse_args() -> #(Int, Int) {
  case argv.load().arguments {
    [num_nodes_str, num_requests_str] -> {
      let assert Ok(num_nodes) = num_nodes_str |> int.parse
      let assert Ok(num_requests) = num_requests_str |> int.parse
      #(num_nodes, num_requests)
    }
    _ -> {
      io.println("Usage: project3 numNodes numRequests")
      panic
    }
  }
}

// ---------------------------------------------------------------------------
// Hashing helpers
// ---------------------------------------------------------------------------

pub fn hash_data(input: String) -> String {
  crypto.hash(crypto.Sha1, input |> bit_array.from_string)
  |> bit_array.base16_encode
}

pub fn hash_node(input: Int) -> String {
  let interm =
    crypto.hash(crypto.Sha1, input |> int.to_base2 |> bit_array.from_string)

  interm |> bit_array.base16_encode
}

// ---------------------------------------------------------------------------
// Liveness & actor utilities
// ---------------------------------------------------------------------------

pub fn is_alive_sub(
  node_id: String,
  state: ChordNodeState,
) -> #(Bool, Subject(ChordNodeMessage)) {
  // Look up node in the routing table and return its liveness and subject
  let assert Ok(node_tup) = dict.get(state.routing_table, node_id)
  #(process.is_alive(node_tup.1), node_tup.0)
}

// ---------------------------------------------------------------------------
// Periodic background tasks
// ---------------------------------------------------------------------------

/// Send FixFingers to every node periodically. This function loops
/// recursively to keep running.
pub fn run_periodic_fix_fingers(
  state: #(Subject(Int), List(#(Subject(ChordNodeMessage), Pid))),
  message: Int,
) -> actor.Next(#(Subject(Int), List(#(Subject(ChordNodeMessage), Pid))), Int) {
  case message {
    0 -> actor.stop()
    _ -> {
      list.each(state.1, fn(tup) { actor.send(tup.0, FixFingers) })
      process.sleep(short_wait_time)
      actor.send(state.0, 1)
      actor.continue(state)
    }
  }
}

/// Send Stabilize to every node periodically. This function loops
/// recursively to keep running.
pub fn run_periodic_stabilize(
  state: #(Subject(Int), List(#(Subject(ChordNodeMessage), Pid))),
  message: Int,
) -> actor.Next(#(Subject(Int), List(#(Subject(ChordNodeMessage), Pid))), Int) {
  case message {
    0 -> actor.stop()
    _ -> {
      list.each(state.1, fn(tup) { actor.send(tup.0, Stabilize) })
      process.sleep(medium_wait_time)
      actor.send(state.0, 1)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Ring arithmetic helpers (id ranges)
// ---------------------------------------------------------------------------

/// Check whether `id` lies in the ring interval (start, end) or (start, end].
/// All ids are hex strings (base16). Uses integer comparisons after parsing.
pub fn in_range(
  id: String,
  start: String,
  end: String,
  inclusive_upper: Bool,
) -> Bool {
  let assert Ok(x) = int.base_parse(id, 16)
  let assert Ok(a) = int.base_parse(start, 16)
  let assert Ok(b) = int.base_parse(end, 16)

  let is_before_end = case inclusive_upper {
    True -> x <= b
    False -> x < b
  }

  case True {
    // Normal range, no wrap-around
    _ if a < b -> a < x && is_before_end

    // Range wraps around 0
    _ if a > b -> x > a || is_before_end

    // a == b, the range covers the entire ring
    _ -> True
  }
}

// ---------------------------------------------------------------------------
// Small numeric helper
// ---------------------------------------------------------------------------

/// Compute integer power base^exponent. The underlying int.power returns a
/// float, so we round the value to produce an integer result.
pub fn int_power(base: Int, exponent: Int) -> Int {
  let assert Ok(x) = int.power(base, int.to_float(exponent))
  x |> float.round
}
