import birl
import birl/duration
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor

// import gleam/result
// import gleam/string

const long_wait_time = 100_000

const actor_count = 100

pub fn main() -> Nil {
  let rumor = "Mario has a crush on Princess Peach."

  let ts1 = birl.now()
  let subjects = create_actors(actor_count)
  let assert Ok(random_sub) = list.sample(subjects, 1) |> list.first
  echo actor.call(
    random_sub,
    sending: fn(sub) { ReceiveRumor(Rumor(rumor, 0), sub) },
    waiting: long_wait_time,
  )
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
            rumor: Rumor("", 0),
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

  // Propogate list of all subjects to all actors, essentially forming a connection
  list.each(subjects, fn(sub) {
    // let _ = actor.call(sub, StoreSubjects(subjects))
    actor.call(
      sub,
      sending: fn(reply_box) { StoreSubjects(subjects, reply_box) },
      waiting: long_wait_time,
    )
    // actor.send(sub, PrintIndex)
  })

  io.println(
    "Stored and created subjects for "
    <> subjects |> list.length |> int.to_string
    <> " actors",
  )

  subjects
}

pub type ActorMessage {
  StoreSubjects(List(Subject(ActorMessage)), Subject(Bool))
  ReceiveRumor(Rumor, Subject(Bool))
  PrintIndex
}

pub type ActorState {
  ActorState(
    subjects: List(Subject(ActorMessage)),
    rumor: Rumor,
    actor_index: Int,
    self_subject: Subject(ActorMessage),
  )
}

pub type Rumor {
  Rumor(rumor: String, head_count: Int)
}

pub fn handle_message(
  state: ActorState,
  message: ActorMessage,
) -> actor.Next(ActorState, ActorMessage) {
  case message {
    PrintIndex -> {
      io.println("I am actor " <> state.actor_index |> int.to_string)
      actor.continue(state)
    }

    StoreSubjects(subjects, reply_to) -> {
      let new_state =
        ActorState(subjects, state.rumor, state.actor_index, state.self_subject)
      actor.send(reply_to, True)

      actor.continue(new_state)
    }

    ReceiveRumor(rumor, reply_to) -> {
      assert state.subjects |> list.length == actor_count
      io.println(
        "Actor " <> state.actor_index |> int.to_string <> " got a rumor",
      )
      actor.send(state.self_subject, PrintIndex)

      case state.rumor.head_count < 10 {
        True -> {
          let new_state =
            ActorState(
              state.subjects,
              Rumor(rumor.rumor, head_count: state.rumor.head_count + 1),
              state.actor_index,
              state.self_subject,
            )
          assert new_state.subjects |> list.length == actor_count
          assert new_state.rumor.head_count > 0
          let assert Ok(random_sub) =
            state.subjects |> list.sample(1) |> list.first
          let assert True =
            actor.call(
              random_sub,
              sending: fn(sub) { ReceiveRumor(rumor, sub) },
              waiting: long_wait_time,
            )
          echo new_state.rumor.head_count
          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        False -> {
          io.println(
            "Actor "
            <> state.actor_index |> int.to_string
            <> " achieved convergence",
          )
          actor.send(reply_to, True)
          actor.continue(state)
        }
      }
    }
  }
}
