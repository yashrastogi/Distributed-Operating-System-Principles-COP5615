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

// --- Constants ---
const long_wait_time = 100_000

const short_wait_time = 1000

const push_sum_convergence_threshold = 1.0e-10

const gossip_convergence_threshold = 10

const gossip_threshold = 1

const actor_sleep = 0

const main_thread_sleep = 0

// --- Main Application Logic ---

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
    "push-sum" -> actor.send(random_sub, PushSum)
    _ -> actor.send(random_sub, ReceiveRumor(rumor))
  }

  // Recursively check until all actors have converged
  check_actors_status(subjects)

  process.sleep(main_thread_sleep)
  let ts2 = birl.now()
  io.println(
    "\n\nConvergence for "
    <> int.to_string(actor_count)
    <> " actors with "
    <> topology
    <> " topology and "
    <> algorithm
    <> " algorithm took:\n",
  )
  echo birl.difference(ts2, ts1) |> duration.decompose()
  Nil
}

pub fn parse_args() -> #(Int, String, String) {
  case argv.load().arguments {
    [num_nodes_str, topology, algorithm] -> {
      case int.parse(num_nodes_str) {
        Ok(num_nodes) -> #(num_nodes, topology, algorithm)
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

/// Recursively polls actors until one reports a converged status.
pub fn check_actors_status(subjects: List(Subject(ActorMessage))) {
  // We stop waiting when one actor has converged.
  case
    list.any(subjects, fn(sub) {
      actor.call(sub, waiting: short_wait_time, sending: GetStatus)
    })
  {
    True -> Nil
    // One actor returned True, so we're done.
    False -> check_actors_status(subjects)
    // No actor is done, check again.
  }
}

// --- Actor Creation and Topology Setup ---

pub fn create_actors(
  count: Int,
  topology: String,
) -> List(Subject(ActorMessage)) {
  let subjects =
    list.range(1, count)
    |> list.map(fn(i) {
      let assert Ok(actor) =
        actor.new_with_initialiser(long_wait_time, fn(self_sub) {
          // Initialize the actor's state
          ActorState(
            subjects: [],
            rumor_content: "",
            rumor_count: 0,
            actor_index: i,
            self_subject: self_sub,
            sum: int.to_float(i),
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

  // Assign neighbors based on the chosen topology
  case topology {
    "line" -> setup_line_topology(subjects, [])
    "3d" -> setup_3d_topology(subjects, False)
    "imp3d" -> setup_3d_topology(subjects, True)
    // Default to a fully connected (full) topology
    _ -> list.each(subjects, fn(sub) { assign_neighbors(sub, subjects) })
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

/// A helper function to send a list of neighbors to an actor.
fn assign_neighbors(
  subject: Subject(ActorMessage),
  neighbors: List(Subject(ActorMessage)),
) {
  actor.call(
    subject,
    sending: fn(reply_box) { StoreSubjects(neighbors, reply_box) },
    waiting: long_wait_time,
  )
}

/// Sets up actor neighbors in a line formation (each actor connects to i-1 and i+1).
pub fn setup_line_topology(
  subjects: List(Subject(ActorMessage)),
  prev_subjects: List(Subject(ActorMessage)),
) {
  case subjects {
    [] -> Nil

    [current_subject, ..rest_of_subjects] -> {
      let next_neighbor = list.take(rest_of_subjects, 1)
      let neighbors = list.append(prev_subjects, next_neighbor)

      assign_neighbors(current_subject, neighbors)

      setup_line_topology(rest_of_subjects, [current_subject])
    }
  }
}

/// Sets up actor neighbors in a 3D grid, with an option for an imperfect grid.
fn setup_3d_topology(subjects: List(Subject(ActorMessage)), is_imperfect: Bool) {
  let side =
    list.length(subjects)
    |> int.to_float
    |> float.power(1.0 /. 3.0)
    |> result.unwrap(or: 0.0)
    |> float.ceiling
    |> float.round

  // Map each actor to a 3D coordinate
  let mapping_list =
    list.index_map(subjects, fn(sub, i) {
      #(#(i % side, { i / side } % side, i / { side * side }), sub)
    })
  let mapping_dict = dict.from_list(mapping_list)

  let offsets = [
    #(-1, 0, 0),
    #(1, 0, 0),
    #(0, -1, 0),
    #(0, 1, 0),
    #(0, 0, -1),
    #(0, 0, 1),
  ]

  list.each(mapping_list, fn(tuple) {
    let coord = tuple.0
    let subject = tuple.1

    // Find all adjacent neighbors in the grid using the offset list
    let grid_neighbors =
      list.filter_map(offsets, fn(offset) {
        let neighbor_coord = #(
          coord.0 + offset.0,
          coord.1 + offset.1,
          coord.2 + offset.2,
        )
        dict.get(mapping_dict, neighbor_coord)
      })

    let final_neighbors = case is_imperfect {
      False -> grid_neighbors
      True -> {
        // For an imperfect grid, add one random, non-adjacent neighbor
        let grid_neighbors_set = set.from_list(grid_neighbors)
        let assert Ok(random_neighbor) =
          subjects
          |> list.filter(fn(s) {
            s != subject && !set.contains(grid_neighbors_set, s)
          })
          |> list.sample(1)
          |> list.first
        [random_neighbor, ..grid_neighbors]
      }
    }
    assign_neighbors(subject, final_neighbors)
  })
}

// --- Actor Types and Message Handler ---

pub type ActorMessage {
  StoreSubjects(subjects: List(Subject(ActorMessage)), reply_box: Subject(Bool))
  ReceiveRumor(rumor: String)
  ReceiveSumPair(s: Float, w: Float)
  PushSum
  GetStatus(reply_box: Subject(Bool))
}

pub type ActorState {
  ActorState(
    subjects: List(Subject(ActorMessage)),
    rumor_content: String,
    rumor_count: Int,
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
    // --- Push-Sum Messages ---
    PushSum -> {
      // The main thread initiates the push-sum algorithm on one actor
      halve_and_send(state)
    }

    ReceiveSumPair(s, w) -> {
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

      let new_state =
        ActorState(
          ..state,
          sum: new_sum,
          weight: new_weight,
          ratio_convergence_streak: new_ratio_convergence_streak,
        )

      case is_converged(new_state) {
        False -> {
          io.println(
            "s/w of actor "
            <> int.to_string(state.actor_index)
            <> ": "
            <> float.to_string(new_sw_ratio),
          )
          halve_and_send(new_state)
        }
        True -> {
          io.println(
            "Actor "
            <> int.to_string(state.actor_index)
            <> " converged with s/w ratio: "
            <> float.to_string(new_sw_ratio),
          )
          actor.continue(new_state)
        }
      }
    }

    // --- Gossip Messages ---
    ReceiveRumor(rumor_content) -> {
      let new_count = state.rumor_count + 1
      let new_state =
        ActorState(
          ..state,
          rumor_content: rumor_content,
          rumor_count: new_count,
        )

      case is_converged(new_state) {
        False -> {
          gossip(new_state, ReceiveRumor(rumor_content), gossip_threshold)
          io.println(
            "Actor "
            <> int.to_string(state.actor_index)
            <> " gossiped to "
            <> int.to_string(gossip_threshold)
            <> " neighbor(s)",
          )
          actor.continue(new_state)
        }
        True -> {
          io.println(
            "Actor " <> int.to_string(state.actor_index) <> " converged already",
          )
          actor.continue(new_state)
        }
      }
    }

    // --- Utility Messages ---
    StoreSubjects(subjects, reply_to) -> {
      let new_state = ActorState(..state, subjects: subjects)
      io.println(
        "Actor "
        <> int.to_string(state.actor_index)
        <> " has "
        <> int.to_string(list.length(subjects))
        <> " neighbor(s)",
      )
      actor.send(reply_to, True)
      actor.continue(new_state)
    }

    GetStatus(reply_to) -> {
      actor.send(reply_to, is_converged(state))
      actor.continue(state)
    }
  }
}

// --- Actor Logic Helpers ---

/// Checks if an actor has met the convergence criteria for either algorithm.
fn is_converged(state: ActorState) -> Bool {
  state.rumor_count >= gossip_convergence_threshold
  || state.ratio_convergence_streak >= 3
}

/// A generic function to send a message to a number of random neighbors.
fn gossip(state: ActorState, message: ActorMessage, count: Int) -> Nil {
  let other_actors =
    state.subjects
    |> list.filter(fn(sub) { sub != state.self_subject })

  let gossip_targets = list.sample(other_actors, count)
  process.sleep(actor_sleep)
  list.each(gossip_targets, fn(target) { actor.send(target, message) })
}

/// The core logic for push-sum: halve sum/weight, keep one half, send the other.
fn halve_and_send(state: ActorState) -> actor.Next(ActorState, ActorMessage) {
  // Halve the current sum and weight for the new state
  let new_state =
    ActorState(..state, sum: state.sum /. 2.0, weight: state.weight /. 2.0)

  // The other half is sent to the neighbor
  let message_to_send =
    ReceiveSumPair(
      s: state.sum -. new_state.sum,
      w: state.weight -. new_state.weight,
    )

  gossip(state, message_to_send, 1)
  actor.continue(new_state)
}
