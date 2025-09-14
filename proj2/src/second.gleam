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

const actor_count = 8

const convergence_threshold = 10

const gossip_threshold = 2

pub fn main() -> Nil {
  let rumor = "Mario has a crush on Princess Peach."

  let ts1 = birl.now()
  let subjects = create_actors(actor_count, "imp3d")
  let assert Ok(random_sub) = list.sample(subjects, 1) |> list.first

  // Start the gossip - just send the rumor content
  actor.send(random_sub, ReceiveRumor(rumor))

  // Wait for propagation to complete
  process.sleep(9000)

  let ts2 = birl.now()
  echo birl.difference(ts2, ts1) |> duration.decompose()

  Nil
}

fn line_sub(
  count: Int,
  subjects: List(Subject(ActorMessage)),
  temp: List(Subject(ActorMessage)),
) {
  case count > 0 {
    True -> {
      let assert Ok(first_sub) = subjects |> list.first
      let subjects = list.drop(subjects, 1)
      case count == 1 {
        False -> {
          let assert Ok(second_sub) = subjects |> list.first
          let temp = list.append(temp, [first_sub, second_sub])
          actor.call(
            first_sub,
            sending: fn(reply_box) { StoreSubjects(temp, reply_box) },
            waiting: long_wait_time,
          )
          line_sub(count - 1, subjects, [first_sub])
        }

        True -> {
          let temp = list.append(temp, [first_sub])
          let temp = list.drop(temp, int.max(list.length(temp) - 2, 0))
          actor.call(
            first_sub,
            sending: fn(reply_box) { StoreSubjects(temp, reply_box) },
            waiting: long_wait_time,
          )
          line_sub(count - 1, subjects, temp)
        }
      }
    }

    False -> {
      Nil
    }
  }
}

fn three_d_sub(subjects: List(Subject(ActorMessage)), setup: String) {
  let side =
    float.power(int.to_float(actor_count), 1.0 /. 3.0)
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
      line_sub(actor_count, subjects, [])
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
    <> " actors",
  )

  subjects
}

pub type ActorMessage {
  StoreSubjects(subjects: List(Subject(ActorMessage)), reply_box: Subject(Bool))
  ReceiveRumor(String)
  PrintIndex
}

pub type ActorState {
  ActorState(
    subjects: List(Subject(ActorMessage)),
    rumor_content: String,
    rumor_count: Int,
    // Internal count of how many times heard
    actor_index: Int,
    self_subject: Subject(ActorMessage),
  )
}

pub fn handle_message(
  state: ActorState,
  message: ActorMessage,
) -> actor.Next(ActorState, ActorMessage) {
  case message {
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
          state.actor_index,
          state.self_subject,
        )
      io.println(
        "Actor "
        <> state.actor_index |> int.to_string
        <> " has "
        <> list.length(subjects) |> int.to_string,
      )
      list.each(state.subjects, fn(sub) { actor.send(sub, PrintIndex) })
      actor.send(reply_to, True)
      actor.continue(new_state)
    }

    ReceiveRumor(rumor_content) -> {
      // Increment this actor's internal count of hearing the rumor
      let new_count = state.rumor_count + 1

      // io.println(
      //   "Actor "
      //   <> int.to_string(state.actor_index)
      //   <> " heard rumor "
      //   <> int.to_string(new_count)
      //   <> " times",
      // )

      let new_state =
        ActorState(
          state.subjects,
          rumor_content,
          // Store the rumor content
          new_count,
          // Update internal count
          state.actor_index,
          state.self_subject,
        )

      // Check if this actor has achieved convergence
      case new_count < convergence_threshold {
        True -> {
          // Haven't converged yet, continue gossiping
          // Select random neighbors to gossip to (exclude self)
          let other_actors =
            state.subjects
            |> list.filter(fn(sub) { sub != state.self_subject })

          // Gossip to a few random neighbors
          let gossip_targets = list.sample(other_actors, gossip_threshold)
          // echo list.length(gossip_targets)

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
          actor.stop()
        }
      }
    }
  }
}
