import birl
import birl/duration
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

const long_wait_time = 100_000

const actor_count = 100

const convergence_threshold = 10

const gossip_threshold = 1

pub fn main() -> Nil {
  let rumor = "Mario has a crush on Princess Peach."

  let ts1 = birl.now()
  let subjects = create_actors(actor_count)
  let assert Ok(random_sub) = list.sample(subjects, 1) |> list.first

  // Start the gossip - just send the rumor content
  actor.send(random_sub, ReceiveRumor(rumor))

  // Wait for propagation to complete
  process.sleep(2000)

  let ts2 = birl.now()
  echo birl.difference(ts2, ts1) |> duration.decompose()

  Nil
}

pub fn create_actors(count: Int) -> List(Subject(ActorMessage)) {
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

  // Propagate list of all subjects to all actors
  list.each(subjects, fn(sub) {
    actor.call(
      sub,
      sending: fn(reply_box) { StoreSubjects(subjects, reply_box) },
      waiting: long_wait_time,
    )
  })

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
            "Actor " <> int.to_string(state.actor_index) <> " not propogating",
          )
          actor.stop()
        }
      }
    }
  }
}
