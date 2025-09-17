import argv
import birl
import birl/duration
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set

const long_wait_time = 100_000

const short_wait_time = 1000

const push_sum_convergence_threshold = 1.0e-10

const gossip_convergence_threshold = 10

// Has to be one! or else push-sum fails
const gossip_threshold = 1

const actor_sleep = 0

const main_thread_sleep = 0

pub fn parse_args() -> #(Int, String, String) {
  let args = argv.load().arguments
  case args {
    [num_nodes_str, topology, algorithm] -> {
      case int.parse(num_nodes_str) {
        Ok(num_nodes) -> {
          #(num_nodes, topology, algorithm)
        }
        Error(_) -> {
          io.println("Invalid numNodes!")
          panic
        }
      }
    }
    _ -> {
      io.println("Usage: project2 numNodes topology algorithm")
      panic
    }
  }
}

pub fn check_actors_status(subjects: List(Subject(ActorMessage))) {
  case
    list.any(subjects, fn(sub) {
      actor.call(sub, waiting: short_wait_time, sending: GetStatus)
    })
  {
    True -> Nil
    False -> check_actors_status(subjects)
  }
}

pub fn main() -> Nil {
  let rumor = "Mario has a crush on Princess Peach."
  let #(actor_count, topology, algorithm) = parse_args()

  let subjects = create_actors(actor_count, topology)
  let assert Ok(random_sub) = list.sample(subjects, 1) |> list.first
  io.println(
    "Main thread will sleep for " <> int.to_string(main_thread_sleep) <> "ms",
  )
  let ts1 = birl.now()
  case algorithm {
    "push-sum" -> {
      actor.send(random_sub, PushSum)
    }

    // Gossip
    _ -> {
      actor.send(random_sub, ReceiveRumor(rumor))
    }
  }

  // Check status recursively
  check_actors_status(subjects)

  // Wait for propagation to complete
  process.sleep(main_thread_sleep)

  let ts2 = birl.now()
  io.println(
    "\n\nConvergence for "
    <> actor_count |> int.to_string
    <> " actors with "
    <> topology
    <> " topology and "
    <> algorithm
    <> " algorithm took:\n",
  )
  echo birl.difference(ts2, ts1) |> duration.decompose()

  Nil
}

fn line_sub(
  subjects: List(Subject(ActorMessage)),
  temp: List(Subject(ActorMessage)),
) {
  let count = list.length(subjects)
  case count > 0 {
    True -> {
      let assert Ok(first_sub) = subjects |> list.first
      let subjects = list.drop(subjects, 1)
      let temp = list.append(temp, [first_sub])
      let temp = case count {
        1 -> {
          temp
          |> list.drop(int.max(list.length(temp) - 2, 0))
        }

        _ -> {
          let assert Ok(second_sub) = subjects |> list.first
          list.append(temp, [second_sub])
        }
      }
      actor.call(
        first_sub,
        sending: fn(reply_box) { StoreSubjects(temp, reply_box) },
        waiting: long_wait_time,
      )
      line_sub(subjects, [first_sub])
    }

    _ -> Nil
  }
}

fn three_d_sub(subjects: List(Subject(ActorMessage)), setup: String) {
  let side =
    float.power(int.to_float(list.length(subjects)), 1.0 /. 3.0)
    |> result.unwrap(0.0)
    |> float.ceiling
    |> float.round

  // x = i % side
  // y = (i / side) % side
  // z = i / (side * side)
  let mapping_list =
    list.index_map(subjects, fn(sub, i) {
      #(#(i % side, { i / side } % side, i / { side * side }), sub)
    })
  let mapping_dict = dict.from_list(mapping_list)
  list.each(mapping_list, fn(tuple) {
    let coord = tuple.0
    let sub = tuple.1
    let sub_nei = []
    let n1 = #(coord.0 - 1, coord.1, coord.2)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n1) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let n2 = #(coord.0 + 1, coord.1, coord.2)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n2) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let n3 = #(coord.0, coord.1 - 1, coord.2)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n3) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let n4 = #(coord.0, coord.1 + 1, coord.2)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n4) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let n5 = #(coord.0, coord.1, coord.2 - 1)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n5) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let n6 = #(coord.0, coord.1, coord.2 + 1)
    let sub_nei =
      list.append(
        case mapping_dict |> dict.get(n6) {
          Ok(sub) -> [sub]
          Error(_) -> []
        },
        sub_nei,
      )
    let sub_nei =
      list.append(sub_nei, case setup {
        "imperfect" -> {
          let sub_nei_set = set.from_list(sub_nei)
          let assert Ok(rand_sub) =
            subjects
            |> list.filter(fn(sub) { !set.contains(sub_nei_set, sub) })
            |> list.sample(1)
            |> list.first
          [rand_sub]
        }
        _ -> {
          []
        }
      })
    actor.call(
      sub,
      sending: fn(reply_box) { StoreSubjects(sub_nei, reply_box) },
      waiting: long_wait_time,
    )
  })
  Nil
}

pub fn create_actors(
  count: Int,
  topology: String,
) -> List(Subject(ActorMessage)) {
  // Create actors and store their subjects
  let subjects =
    list.range(1, count)
    |> list.map(fn(i) {
      let assert Ok(actor) =
        actor.new_with_initialiser(long_wait_time, fn(self_sub) {
          ActorState(
            subjects: [],
            rumor_content: "",
            rumor_count: 0,
            actor_index: i,
            self_subject: self_sub,
            sum: i |> int.to_float,
            weight: 1.0,
            ratio_convergence_streak: 0,
          )
          |> actor.initialised
          |> actor.returning(self_sub)
          |> Ok
        })
        |> actor.on_message(handle_message)
        |> actor.start
      actor.data
    })

  case topology {
    "line" -> {
      line_sub(subjects, [])
    }

    "3d" -> {
      three_d_sub(subjects, "perfect")
    }

    "imp3d" -> {
      three_d_sub(subjects, "imperfect")
    }

    _ -> {
      // Propagate list of all subjects to all actors
      list.each(subjects, fn(sub) {
        actor.call(
          sub,
          sending: fn(reply_box) { StoreSubjects(subjects, reply_box) },
          waiting: long_wait_time,
        )
      })
    }
  }

  io.println(
    "Created and initialized "
    <> int.to_string(list.length(subjects))
    <> " actors with "
    <> topology
    <> " topology",
  )

  subjects
}

pub type ActorMessage {
  StoreSubjects(subjects: List(Subject(ActorMessage)), reply_box: Subject(Bool))
  ReceiveRumor(rumor: String)
  ReceiveSumPair(s: Float, w: Float)
  PrintIndex
  PushSum
  GetStatus(reply_box: Subject(Bool))
}

pub type ActorState {
  ActorState(
    subjects: List(Subject(ActorMessage)),
    // Asynchronous Gossip - Information Propogation
    rumor_content: String,
    rumor_count: Int,
    // Asynchronous Gossip - Push Sum
    sum: Float,
    weight: Float,
    actor_index: Int,
    self_subject: Subject(ActorMessage),
    ratio_convergence_streak: Int,
  )
}

pub fn handle_message(
  state: ActorState,
  message: ActorMessage,
) -> actor.Next(ActorState, ActorMessage) {
  case message {
    PushSum -> {
      // One time command to start push sum received from main
      // Select random neighbors to gossip to (exclude self)
      let other_actors =
        state.subjects
        |> list.filter(fn(sub) { sub != state.self_subject })

      // Gossip to a random neighbor
      let gossip_targets = list.sample(other_actors, 1)

      let new_state =
        ActorState(
          state.subjects,
          state.rumor_content,
          state.rumor_count,
          state.sum /. 2.0,
          state.weight /. 2.0,
          state.actor_index,
          state.self_subject,
          state.ratio_convergence_streak,
        )

      process.sleep(actor_sleep)

      list.each(gossip_targets, fn(target) {
        actor.send(
          target,
          ReceiveSumPair(
            state.sum -. new_state.sum,
            state.weight -. new_state.weight,
          ),
        )
      })

      actor.continue(new_state)
    }

    ReceiveSumPair(s, w) -> {
      // Receive: Messages sent and received are pairs of the form (s, w). Upon
      // receiving, an actor adds the received pair to its own corresponding val-
      // ues. After receiving, each actor selects a random neighbor and sends it a
      // message.

      let new_sum = state.sum +. s
      let new_weight = state.weight +. w

      let old_sw_ratio = state.sum /. state.weight
      let new_sw_ratio = new_sum /. new_weight
      let new_ratio_convergence_streak = case
        float.absolute_value(new_sw_ratio -. old_sw_ratio)
        <. push_sum_convergence_threshold
      {
        True -> state.ratio_convergence_streak + 1
        False -> 0
      }

      case new_ratio_convergence_streak >= 3 {
        False -> {
          // Didn't converge so go on

          // Select random neighbors to gossip to (exclude self)
          let other_actors =
            state.subjects
            |> list.filter(fn(sub) { sub != state.self_subject })

          // Gossip to random neighbors
          let gossip_targets = list.sample(other_actors, gossip_threshold)

          let new_state =
            ActorState(
              state.subjects,
              state.rumor_content,
              state.rumor_count,
              new_sum /. 2.0,
              new_weight /. 2.0,
              state.actor_index,
              state.self_subject,
              new_ratio_convergence_streak,
            )

          process.sleep(actor_sleep)

          list.each(gossip_targets, fn(target) {
            actor.send(
              target,
              ReceiveSumPair(
                new_sum -. new_state.sum,
                new_weight -. new_state.weight,
              ),
            )
          })

          io.println(
            "s/w of actor "
            <> state.actor_index |> int.to_string
            <> ": "
            <> { state.sum /. state.weight } |> float.to_string,
          )
          actor.continue(new_state)
        }
        True -> {
          // Converged: stop propogation
          io.println(
            "Actor "
            <> int.to_string(state.actor_index)
            <> " converged already with s/w ratio: "
            <> { state.sum /. state.weight } |> float.to_string,
          )
          let new_state =
            ActorState(
              state.subjects,
              state.rumor_content,
              state.rumor_count,
              state.sum,
              state.weight,
              state.actor_index,
              state.self_subject,
              new_ratio_convergence_streak,
            )
          actor.continue(new_state)
        }
      }
    }

    PrintIndex -> {
      io.println("I am actor " <> int.to_string(state.actor_index))
      actor.continue(state)
    }

    StoreSubjects(subjects, reply_to) -> {
      let new_state =
        ActorState(
          subjects,
          state.rumor_content,
          state.rumor_count,
          state.sum,
          state.weight,
          state.actor_index,
          state.self_subject,
          state.ratio_convergence_streak,
        )
      io.println(
        "Actor "
        <> state.actor_index |> int.to_string
        <> " has "
        <> list.length(subjects) |> int.to_string
        <> " neighbor(s)",
      )
      list.each(state.subjects, fn(sub) { actor.send(sub, PrintIndex) })
      actor.send(reply_to, True)
      actor.continue(new_state)
    }

    ReceiveRumor(rumor_content) -> {
      // Increment this actor's internal count of hearing the rumor
      let new_count = state.rumor_count + 1
      let new_state =
        ActorState(
          state.subjects,
          rumor_content,
          // Store the rumor content
          new_count,
          // Update internal count
          state.sum,
          state.weight,
          state.actor_index,
          state.self_subject,
          state.ratio_convergence_streak,
        )

      // Check if this actor has achieved convergence
      case new_count < gossip_convergence_threshold {
        True -> {
          // Haven't converged yet, continue gossiping
          // Select random neighbors to gossip to (exclude self)
          let other_actors =
            state.subjects
            |> list.filter(fn(sub) { sub != state.self_subject })

          // Gossip to a few random neighbors
          let gossip_targets = list.sample(other_actors, gossip_threshold)

          process.sleep(actor_sleep)

          list.each(gossip_targets, fn(target) {
            actor.send(target, ReceiveRumor(rumor_content))
          })

          io.println(
            "Actor "
            <> int.to_string(state.actor_index)
            <> " gossiped to "
            <> int.to_string(list.length(gossip_targets))
            <> " neighbors",
          )
          actor.continue(new_state)
        }

        False -> {
          io.println(
            "Actor " <> int.to_string(state.actor_index) <> " converged already",
          )
          // Note: new_state
          actor.continue(new_state)
        }
      }
    }

    GetStatus(reply_to) -> {
      actor.send(
        reply_to,
        state.rumor_count >= gossip_convergence_threshold
          || state.ratio_convergence_streak >= 3,
      )
      actor.continue(state)
    }
  }
}
