import argv
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result

// todo: Restart worker on failure

fn sum_of_squares(start: Int, length: Int) -> Int {
  // [n(n+1)(2n+1)] / 6
  case length <= 0 {
    True -> 0
    False -> {
      let end = start + length - 1

      let sum_sq_end = { end * { end + 1 } * { 2 * end + 1 } } / 6
      let sum_sq_start_minus_1 =
        { { start - 1 } * start * { 2 * start - 1 } } / 6

      sum_sq_end - sum_sq_start_minus_1
    }
  }
}

pub fn main() -> Nil {
  case argv.load().arguments {
    [arg_n, arg_k, arg_batch_size] -> run_program(arg_n, arg_k, arg_batch_size)
    [arg_n, arg_k] -> run_program(arg_n, arg_k, "1")
    _ -> io.println("usage: ./sumsq N k [batchSize]")
  }
  Nil
}

fn run_program(arg_n: String, arg_k: String, arg_batch_size: String) -> Nil {
  let n = result.unwrap(int.parse(arg_n), 0)
  let k = arg_k |> int.parse() |> result.unwrap(0)
  let batch_size = arg_batch_size |> int.parse() |> result.unwrap(0)
  let assert Ok(boss) =
    actor.new(#([], 0, [])) |> actor.on_message(boss_actor_fn) |> actor.start
  actor.send(boss.data, Solve(n, k, batch_size, boss.data))

  echo actor.call(boss.data, waiting: 100_000, sending: GetResults)

  // let batch_list = create_batch_list(n, k, batch_size, 1)
  // io.println("Number of batches: " <> int.to_string(list.length(batch_list)))
  // let result =
  //   working_actors.spawn_workers(batch_size, batch_list, checker)
  //   |> list.flatten()
  // // result |> list.map(fn(x) { io.println(int.to_string(x)) })
  // io.println("Number of entries: " <> int.to_string(list.length(result)))
  // echo result
  Nil
}

pub type BossMessage {
  Solve(Int, Int, Int, process.Subject(BossMessage))
  GetResults(process.Subject(List(Int)))
  PostResults(List(Int))
}

fn boss_actor_fn(
  state: #(List(Int), Int, List(process.Subject(List(Int)))),
  message: BossMessage,
) -> actor.Next(
  #(List(Int), Int, List(process.Subject(List(Int)))),
  BossMessage,
) {
  case message {
    Solve(n, k, batch_size, boss_subject) -> {
      let chunks =
        list.range(1, n)
        |> list.sized_chunk(batch_size)

      chunks
      |> list.map(fn(chunk) {
        // echo chunk
        let resp =
          actor.new(#(
            list.first(chunk) |> result.unwrap(0),
            list.last(chunk) |> result.unwrap(0),
            k,
            boss_subject,
          ))
          |> actor.on_message(checker)
          |> actor.start
        // echo resp
        let assert Ok(worker) = resp
        actor.send(worker.data, Check)
      })
      io.println("Number of chunks: " <> int.to_string(list.length(chunks)))
      let new_state = #(state.0, list.length(chunks), state.2)
      // echo new_state
      actor.continue(new_state)
    }

    PostResults(results) -> {
      let new_pending = state.1 - 1
      let new_state = #(list.append(state.0, results), new_pending, state.2)
      // echo new_state
      case new_pending == 0 {
        True -> {
          state.2
          |> list.map(fn(reply_box) { actor.send(reply_box, new_state.0) })
          actor.continue(#([], 0, []))
        }
        False -> {
          actor.continue(new_state)
        }
      }
    }

    GetResults(reply) -> {
      case state.1 == 0 {
        True -> {
          actor.send(reply, state.0)
          actor.stop()
        }
        False -> {
          actor.continue(#(state.0, state.1, [reply, ..state.2]))
        }
      }
    }
  }
  // actor.continue(state)
}

pub type WorkerMessage {
  Check
}

// fn checker(tuple: #(Int, Int, Int)) -> List(Int) {
fn checker(
  state: #(Int, Int, Int, process.Subject(BossMessage)),
  message: WorkerMessage,
) -> actor.Next(#(Int, Int, Int, process.Subject(BossMessage)), WorkerMessage) {
  case message {
    Check -> {
      // echo "Hi"
      let #(current, limit, max_terms, boss_subject) = state
      let result =
        list.range(current, limit)
        |> list.map(fn(i) {
          let total = sum_of_squares(i, max_terms)
          let assert Ok(root) = float.square_root(int.to_float(total))

          case root == float.floor(root) {
            True -> i
            False -> -1
          }
        })
        |> list.filter(fn(val) { val != -1 })
      // echo result
      actor.send(boss_subject, PostResults(result))
      actor.stop()
    }
  }
}
