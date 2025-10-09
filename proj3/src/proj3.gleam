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

// --- Constants ---
const long_wait_time = 4000

const medium_wait_time = 1500

const short_wait_time = 500

const main_thread_sleep = 10_000

pub fn main() -> Nil {
  let #(num_nodes, num_requests) = parse_args()
  let #(sub_tups, _routing_table) = create_actors(num_nodes, num_requests)

  let assert Ok(stabilize_actor) =
    actor.new(sub_tups)
    |> actor.on_message(run_periodic_stabilize)
    |> actor.start
  actor.send(stabilize_actor.data, Nil)

  let assert Ok(fix_fingers_actor) =
    actor.new(sub_tups)
    |> actor.on_message(run_periodic_fix_fingers)
    |> actor.start
  actor.send(fix_fingers_actor.data, Nil)

  process.sleep(main_thread_sleep)
  Nil
}

/// A helper function to assign routing table to an actor.
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

fn create_actors(
  num_nodes: Int,
  num_requests: Int,
) -> #(
  List(#(Subject(ChordNodeMessage), process.Pid)),
  Dict(String, #(Subject(ChordNodeMessage), process.Pid)),
) {
  let max_nodes = int_power(2, 160)
  // Create the actors
  let mapping_list =
    list.range(1, num_nodes)
    |> list.map(fn(i) {
      let index = { int.random(max_nodes) } + i
      let index_hash = hash_node(index)

      let assert Ok(n_actor) =
        actor.new_with_initialiser(long_wait_time, fn(self_sub) {
          // Initialize the actor's state
          ChordNodeState(
            routing_table: dict.new(),
            actor_index: index,
            node_id: index_hash,
            self_subject: self_sub,
            node_data: dict.new(),
            num_requests: num_requests,
            successor_id: hash_node(index),
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
      #(index_hash, #(n_actor.data, n_actor.pid))
    })
  // Create sub_tups for backwards compatibility for now
  let sub_tups = list.map(mapping_list, fn(tup) { #(tup.1.0, tup.1.1) })
  // Propogate whole routing table for now
  let routing_table = dict.from_list(mapping_list)
  list.each(sub_tups, fn(tup) { assign_routing_table(tup.0, routing_table) })
  // Join all nodes to an existing node
  let assert Ok(first_mapping) = list.first(mapping_list)
  list.each(sub_tups, fn(tup) { actor.send(tup.0, Join(first_mapping.0)) })
  #(sub_tups, routing_table)
}

pub fn chord_node_handler(
  state: ChordNodeState,
  message: ChordNodeMessage,
) -> actor.Next(ChordNodeState, ChordNodeMessage) {
  // Handle incoming messages
  case message {
    UpdateNodeData(data:) -> {
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

    Ping(reply_to) -> {
      actor.send(reply_to, True)
      actor.continue(state)
    }

    GetPredecessor(reply_to) -> {
      actor.send(reply_to, state.predecessor_id)
      actor.continue(state)
    }

    FindSuccessor(id, reply_to) -> {
      echo "Running find_successor on node " <> state.node_id
      actor.send(reply_to, find_successor(id, state))
      actor.continue(state)
    }

    FixFingers -> {
      let max_nodes = int_power(2, 160)
      let assert Ok(node_id_int) = int.base_parse(state.node_id, 16)
      let finger_id_int =
        { node_id_int + int_power(2, state.fix_finger_number - 1) } % max_nodes
      let finger_id = int.to_base16(finger_id_int)
      let finger_id_successor_id = find_successor(finger_id, state)

      let new_finger_list =
        dict.insert(
          state.finger_list,
          state.fix_finger_number,
          finger_id_successor_id.0,
        )

      io.println(
        "Finger list for node "
        <> state.node_id
        <> " ["
        <> dict.fold(new_finger_list, "", with: fn(acc, _, val) {
          acc <> " | " <> val
        })
        <> " ]",
      )
      let new_state =
        ChordNodeState(
          ..state,
          finger_list: new_finger_list,
          fix_finger_number: { state.fix_finger_number % 160 } + 1,
        )
      actor.continue(new_state)
    }

    Stabilize -> {
      echo "Stabilize on actor "
        <> state.node_id
        <> " successor is "
        <> state.successor_id
        <> " predecessor is "
        <> state.predecessor_id

      // echo "Running stabilize on node " <> state.node_id
      // Validate successor and update accordingly
      let successor_alive = is_alive_sub(state.successor_id, state)
      let result_main = case
        !successor_alive.0 || state.successor_id == state.node_id
      {
        False -> state.successor_id
        // Find next alive successor
        True -> {
          let result =
            list.find_map(state.successor_list, fn(candidate_id) {
              let candidate_alive = is_alive_sub(candidate_id, state)
              case candidate_id != state.node_id && candidate_alive.0 {
                False -> Error(Nil)
                True -> Ok(candidate_id)
              }
            })
          case result {
            Ok(res) -> res
            Error(_) -> state.node_id
          }
        }
      }

      // Check if successor's predecessor might be a better successor
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
            // No predecessor set
            False -> result_main
            // Found a predecessor
            True -> {
              let successor_predecessor =
                is_alive_sub(successor_predecessor_id, state)
              // If true then better successor found, update successor
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

      let new_successor_list = case result_main != state.node_id {
        True -> {
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
          state.successor_list
        }
      }
      let new_finger_list = dict.insert(state.finger_list, 1, result_main)
      let new_state =
        ChordNodeState(
          ..state,
          successor_id: result_main,
          successor_list: new_successor_list,
          finger_list: new_finger_list,
        )
      let new_successor_node = is_alive_sub(result_main, state)
      case result_main != state.node_id {
        True -> actor.send(new_successor_node.1, Notify(state.node_id))
        _ -> Nil
      }
      actor.continue(new_state)
    }

    // TODO: Replicate to r successors
    Put(data:) -> {
      echo "Put called on node " <> state.node_id <> " with data " <> data
      let key = hash_data(data)
      let #(successor_id, _) = find_successor(key, state)

      let new_node_data = case successor_id == state.node_id {
        // store data
        True -> dict.insert(state.node_data, key, data)
        // forward to responsible and return unchanged
        False -> {
          actor.send(is_alive_sub(successor_id, state).1, Put(data))
          state.node_data
        }
      }
      let new_state = ChordNodeState(..state, node_data: new_node_data)
      actor.continue(new_state)
    }

    Get(key:, reply_to:) -> {
      echo "Get called on node " <> state.node_id <> " with key " <> key
      let key_hash = hash_data(key)
      let #(successor_id, hops) = find_successor(key_hash, state)
      case successor_id == state.node_id {
        False ->
          actor.call(
            is_alive_sub(successor_id, state).1,
            sending: fn(reply) { Get(key, reply) },
            waiting: medium_wait_time,
          )

        True -> {
          let assert Ok(res) = dict.get(state.node_data, key_hash)
          #(res, hops + 1)
        }
      }
      actor.send(reply_to, #("", 1))
      actor.continue(state)
    }

    Join(existing_node_id:) -> {
      echo "Join"
      case existing_node_id == state.node_id {
        True -> actor.continue(state)

        False -> {
          io.println(
            "Node " <> state.node_id <> " joining n_id: " <> existing_node_id,
          )
          let existing_node = is_alive_sub(existing_node_id, state)

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
      echo "StoreRoutingTable"
      let new_state = ChordNodeState(..state, routing_table: routing_table)
      actor.send(reply_to, True)
      actor.continue(new_state)
    }

    Notify(potential_predecessor_id:) -> {
      echo "Notify"
      let bool =
        state.predecessor_id == ""
        || in_range(
          potential_predecessor_id,
          state.predecessor_id,
          state.node_id,
          False,
        )
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
          // Delete transferred keys
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

pub fn find_successor(id: String, state: ChordNodeState) {
  case in_range(id, state.node_id, state.successor_id, True) {
    True -> #(state.successor_id, 0)
    False -> {
      let closest_node_id =
        closest_preceding_node(state.finger_list, state.node_id, id)
      case closest_node_id == state.node_id {
        True -> #(state.successor_id, 0)
        False -> {
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

pub type ChordNodeMessage {
  Ping(reply_to: Subject(Bool))
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

// Copies keys in a given range to another node without deleting them locally.
pub fn copy_keys_in_range(
  to_node_id: String,
  from_id: String,
  to_id: String,
  this_node_id: String,
  this_node_data: Dict(String, String),
  state: ChordNodeState,
) -> List(String) {
  let data_to_transfer =
    dict.filter(this_node_data, fn(key, _) {
      case from_id != "" {
        True -> in_range(key, from_id, to_id, True)
        False -> in_range(key, this_node_id, to_id, True)
      }
    })
  let to_node = is_alive_sub(to_node_id, state)
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

pub fn hash_data(input: String) -> String {
  crypto.hash(crypto.Sha1, input |> bit_array.from_string)
  |> bit_array.base16_encode
}

pub fn hash_node(input: Int) -> String {
  let interm =
    crypto.hash(crypto.Sha1, input |> int.to_base2 |> bit_array.from_string)

  interm |> bit_array.base16_encode
}

pub fn is_alive_sub(
  node_id: String,
  state: ChordNodeState,
) -> #(Bool, Subject(ChordNodeMessage)) {
  let assert Ok(node_tup) = dict.get(state.routing_table, node_id)
  #(process.is_alive(node_tup.1), node_tup.0)
}

pub fn run_periodic_fix_fingers(
  state: List(#(Subject(ChordNodeMessage), Pid)),
  _message: Nil,
) -> actor.Next(List(#(Subject(ChordNodeMessage), Pid)), Nil) {
  list.each(state, fn(tup) { actor.send(tup.0, FixFingers) })
  process.sleep(short_wait_time)
  let _ = run_periodic_fix_fingers(state, Nil)
  actor.continue(state)
}

pub fn run_periodic_stabilize(
  state: List(#(Subject(ChordNodeMessage), Pid)),
  _message: Nil,
) -> actor.Next(List(#(Subject(ChordNodeMessage), Pid)), Nil) {
  list.each(state, fn(tup) { actor.send(tup.0, Stabilize) })
  process.sleep(medium_wait_time)
  let _ = run_periodic_stabilize(state, Nil)
  actor.continue(state)
}

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

pub fn int_power(base: Int, exponent: Int) -> Int {
  let assert Ok(x) = int.power(base, int.to_float(exponent))
  x |> float.round
}
