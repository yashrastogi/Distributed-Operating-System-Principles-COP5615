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
import gleam/order.{Eq, Gt, Lt}
import gleam/otp/actor
import gleam/result

// ---------------------------------------------------------------------------
// Constants — timeouts and sleeps (milliseconds)
// ---------------------------------------------------------------------------

const long_wait_time = 4000

const medium_wait_time = 1500

const short_wait_time = 500

/// How long the main thread sleeps after starting background actors.
/// This lets the periodic actors run for a while before the program ends.
const main_thread_sleep = 3000

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  // Parse command line arguments: num_nodes and num_requests
  let #(num_nodes, num_requests) = parse_args()

  // Create all node actors and an initial routing table
  let #(sub_tups, routing_table) = create_actors(num_nodes, num_requests)

  // Start a background actor that periodically calls stabilize on nodes
  let assert Ok(stabilize_actor) =
    actor.new(sub_tups)
    |> actor.on_message(run_periodic_stabilize)
    |> actor.start
  actor.send(stabilize_actor.data, Nil)

  // Start a background actor that periodically calls fix_fingers on nodes
  let assert Ok(fix_fingers_actor) =
    actor.new(sub_tups)
    |> actor.on_message(run_periodic_fix_fingers)
    |> actor.start
  actor.send(fix_fingers_actor.data, Nil)

  // Keep the main thread alive so background actors continue running
  process.sleep(main_thread_sleep)

  dict.each(routing_table, fn(key, _) {
    io.println(
      "Node id is "
      <> key
      <> " in int its "
      <> key |> int.base_parse(16) |> result.unwrap(0) |> int.to_string,
    )
  })

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
  // Maximum identifier space for SHA1 (2^160)
  let max_nodes = int_power(2, 160)

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
            successor_list: [index_hash],
            finger_list: dict.from_list([#(1, index_hash)]),
            predecessor_id: "",
            fix_finger_number: 2,
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
          node_data: dict.combine(data, state.node_data, fn(clash1, _) {
            clash1
          }),
        )
      echo state.node_data
      echo new_state.node_data
      actor.continue(new_state)
    }

    GetPredecessor(reply_to) -> {
      // Return the predecessor id
      actor.send(reply_to, state.predecessor_id)
      actor.continue(state)
    }

    FindSuccessor(id, reply_to) -> {
      // Lookup the successor for the given id and reply with it
      echo "Running find_successor on node " <> state.node_id
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

      io.println(
        "\nFinger list for node "
        <> state.node_id
        <> ":\n["
        <> dict.fold(new_finger_list, "", with: fn(acc, _, val) {
          val <> ", " <> acc
        })
        <> " ]\n",
      )

      // Update the fix_finger_number in a cyclic manner (1..160)
      let new_state =
        ChordNodeState(
          ..state,
          finger_list: new_finger_list,
          fix_finger_number: { state.fix_finger_number % 160 } + 1,
        )
      actor.continue(new_state)
    }

    Stabilize -> {
      // Periodic stabilization: verify successor and notify it if necessary
      echo "Stabilize on actor "
        <> state.node_id
        <> " successor is "
        <> state.successor_id
        <> " predecessor is "
        <> state.predecessor_id

      // Check if the successor is alive
      let successor_alive = is_alive_sub(state.successor_id, state)

      // If successor dead or successor is self, try to find a replacement
      let result_main = case
        !successor_alive.0 || state.successor_id == state.node_id
      {
        False -> state.successor_id
        True -> {
          // Find a live candidate from successor_list
          let result =
            list.find_map(state.successor_list, fn(candidate_id) {
              let candidate_alive = is_alive_sub(candidate_id, state)
              case candidate_id != state.node_id && candidate_alive.0 {
                False -> Error(Nil)
                True -> Ok(candidate_id)
              }
            })
          // In case a live candidate is found, return res, else return self 
          case result {
            Ok(res) -> res
            Error(_) -> state.node_id
          }
        }
      }

      // If we still have a successor candidate, ask that successor for its predecessor
      let result_main = case result_main != state.node_id && successor_alive.0 {
        False -> result_main
        True -> {
          let successor_alive = is_alive_sub(result_main, state)
          let successor_predecessor_id =
            actor.call(
              successor_alive.1,
              waiting: medium_wait_time,
              sending: GetPredecessor,
            )
          case successor_predecessor_id != "" {
            // No predecessor set on the successor
            False -> result_main
            // Found predecessor; check whether it's a better successor
            True -> {
              let successor_predecessor =
                is_alive_sub(successor_predecessor_id, state)
              case
                successor_predecessor.0
                && in_range(
                  successor_predecessor_id,
                  state.node_id,
                  result_main,
                  False,
                )
              {
                False -> result_main
                True -> successor_predecessor_id
              }
            }
          }
        }
      }

      // Rebuild successor_list from the agreed successor
      let new_successor_list = case result_main != state.node_id {
        True -> {
          // Ask the chosen successor for additional successor entries to fill the list
          let new_successor_list_tup =
            list.range(1, 5)
            |> list.map_fold(
              with: fn(memo, _) {
                let res =
                  actor.call(
                    is_alive_sub(memo, state).1,
                    waiting: medium_wait_time,
                    sending: fn(reply_to) {
                      FindSuccessor(result_main, reply_to)
                    },
                  )
                #(res.0, res.0)
              },
              from: result_main,
            )
          [result_main, ..new_successor_list_tup.1]
        }
        False -> {
          // No change
          state.successor_list
        }
      }

      // Update finger table entry 1 to point to the successor
      let new_finger_list = dict.insert(state.finger_list, 1, result_main)

      // Build new state with updated successor, successor_list and finger_list
      let new_state =
        ChordNodeState(
          ..state,
          successor_id: result_main,
          successor_list: new_successor_list,
          finger_list: new_finger_list,
        )

      // If successor changed and is alive, notify it of this node as potential predecessor
      let new_successor_node = is_alive_sub(result_main, state)
      case result_main != state.node_id {
        True -> actor.send(new_successor_node.1, Notify(state.node_id))
        _ -> Nil
      }

      actor.continue(new_state)
    }

    // ---------------------------------------------------------------------
    // Data operations
    // ---------------------------------------------------------------------
    // TODO: Replicate to r successors (currently stores to single responsible node)
    Put(data:) -> {
      echo "Put called on node " <> state.node_id <> " with data " <> data
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

    Get(key:, reply_to:) -> {
      // Retrieve a value for a key. If this node is not responsible, forward
      echo "Get called on node " <> state.node_id <> " with key " <> key
      let key_hash = hash_data(key)
      let #(successor_id, hops) = find_successor(key_hash, state)
      case successor_id == state.node_id {
        False ->
          // Forward call to responsible node synchronously
          actor.call(
            is_alive_sub(successor_id, state).1,
            sending: fn(reply) { Get(key, reply) },
            waiting: medium_wait_time,
          )

        True -> {
          // Attempt to get the value locally (may crash if key missing)
          let assert Ok(res) = dict.get(state.node_data, key_hash)
          #(res, hops + 1)
        }
      }
      // Reply default placeholder (original code returned #("", 1) — preserved)
      actor.send(reply_to, #("", 1))
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
            "Node " <> state.node_id <> " joining n_id: " <> existing_node_id,
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
            <> state.node_id
            <> " successor is "
            <> successor_node_id.0
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

    Notify(potential_predecessor_id:) -> {
      // Successor notifies this node that it might be this node's predecessor.
      // Update predecessor and transfer any keys that should now belong to it.
      echo "Notify"
      let bool =
        state.predecessor_id == ""
        || in_range(
          potential_predecessor_id,
          state.predecessor_id,
          state.node_id,
          False,
        )

      // If the new predecessor should take keys, copy the relevant keys
      let new_predecessor_and_data = case bool {
        False -> #(state.predecessor_id, state.node_data)
        True -> {
          let copied_keys =
            copy_keys_in_range(
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
      let new_state =
        ChordNodeState(
          ..state,
          predecessor_id: new_predecessor,
          node_data: new_node_data,
        )

      actor.continue(new_state)
    }
  }
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
              sending: fn(reply_to) { FindSuccessor(id, reply_to) },
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
  GetPredecessor(reply_to: Subject(String))
  FixFingers
  Put(data: String)
  Get(key: String, reply_to: Subject(#(String, Int)))
  UpdateNodeData(data: Dict(String, String))
  Join(existing_node_id: String)
  Notify(potential_predecessor_id: String)
  FindSuccessor(id: String, reply_to: Subject(#(String, Int)))
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
pub fn copy_keys_in_range(
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
/// recursively to keep running (tail-call style).
pub fn run_periodic_fix_fingers(
  state: List(#(Subject(ChordNodeMessage), Pid)),
  _message: Nil,
) -> actor.Next(List(#(Subject(ChordNodeMessage), Pid)), Nil) {
  list.each(state, fn(tup) { actor.send(tup.0, FixFingers) })
  process.sleep(short_wait_time)
  let _ = run_periodic_fix_fingers(state, Nil)
  actor.continue(state)
}

/// Send Stabilize to every node periodically. This function loops
/// recursively to keep running (tail-call style).
pub fn run_periodic_stabilize(
  state: List(#(Subject(ChordNodeMessage), Pid)),
  _message: Nil,
) -> actor.Next(List(#(Subject(ChordNodeMessage), Pid)), Nil) {
  list.each(state, fn(tup) { actor.send(tup.0, Stabilize) })
  process.sleep(medium_wait_time)
  let _ = run_periodic_stabilize(state, Nil)
  actor.continue(state)
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

/// Variant of in_range using bit_array compare operations (keeps original
/// logic but uses bit_array decoding and a comparison API).
pub fn in_range_2(
  id: String,
  start: String,
  end: String,
  inclusive_upper: Bool,
) -> Bool {
  let assert Ok(x) = bit_array.base16_decode(id)
  let assert Ok(a) = bit_array.base16_decode(start)
  let assert Ok(b) = bit_array.base16_decode(end)
  case inclusive_upper {
    True -> {
      case bit_array.compare(a, b) {
        // a < b
        Lt -> {
          // a < x
          case bit_array.compare(a, x) == Lt {
            True -> {
              // x <= b
              case bit_array.compare(x, b) {
                Lt -> True
                Eq -> True
                _ -> False
              }
            }

            False -> False
          }
        }
        // a == b
        Eq -> True
        // a > b
        Gt -> {
          // x > a
          let pred1 = case bit_array.compare(x, a) == Gt {
            True -> True
            False -> False
          }
          // x <= b
          let pred2 = case bit_array.compare(x, b) {
            Lt -> True
            Eq -> True
            Gt -> False
          }
          pred1 || pred2
        }
      }
    }

    False -> {
      case bit_array.compare(a, b) {
        // a < b
        Lt -> {
          // a < x
          case bit_array.compare(a, x) == Lt {
            True -> {
              // x < b
              case bit_array.compare(x, b) {
                Lt -> True
                Eq -> False
                _ -> False
              }
            }

            False -> False
          }
        }
        // a == b
        Eq -> True
        // a > b
        Gt -> {
          // x > a
          let pred1 = case bit_array.compare(x, a) == Gt {
            True -> True
            False -> False
          }
          // x < b
          let pred2 = case bit_array.compare(x, b) {
            Lt -> True
            Eq -> False
            Gt -> False
          }
          pred1 || pred2
        }
      }
    }
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
