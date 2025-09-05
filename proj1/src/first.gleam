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
    [arg_n, arg_k] -> run_program(arg_n, arg_k, "")
    _ -> io.println("usage: ./sumsq N k [batchSize]")
  }
}

fn run_program(arg_n: String, arg_k: String, arg_batch_size: String) -> Nil {
  let n = result.unwrap(int.parse(arg_n), 0)
  let k = arg_k |> int.parse() |> result.unwrap(0)
  let batch_size =
    arg_batch_size |> int.parse() |> result.unwrap(n / 100) |> int.max(1)
  let assert Ok(boss) =
    actor.new(#([], 0, [])) |> actor.on_message(boss_actor_fn) |> actor.start
  actor.send(boss.data, Solve(n, k, batch_size, boss.data))

  echo actor.call(boss.data, waiting: 1_000_000, sending: GetResults)
  // |> list.sort(by: int.compare)
  // |> list.each(fn(el) { io.println(int.to_string(el)) })
  Nil
}

pub type BossMessage {
  Solve(Int, Int, Int, process.Subject(BossMessage))
  GetResults(process.Subject(List(Int)))
  PostResults(List(Int))
}

fn make_chunks(start: Int, stop: Int, batch_size: Int) -> List(#(Int, Int)) {
  case start > stop {
    True -> []
    False -> {
      let end = int.min(start + batch_size - 1, stop)
      [#(start, end), ..make_chunks(end + 1, stop, batch_size)]
    }
  }
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
      let chunks = make_chunks(1, n, batch_size)
      chunks
      |> list.map(fn(chunk) {
        let #(chunk_start, chunk_end) = chunk
        let resp =
          actor.new(#(chunk_start, chunk_end, k, boss_subject))
          |> actor.on_message(checker)
          |> actor.start
        let assert Ok(worker) = resp
        actor.send(worker.data, Check)
      })
      io.println(
        "Number of chunks: "
        <> int.to_string(list.length(chunks))
        <> ", batch size: "
        <> int.to_string(batch_size),
      )
      let new_state = #(state.0, list.length(chunks), state.2)
      actor.continue(new_state)
    }

    PostResults(results) -> {
      let new_pending = state.1 - 1
      let new_state = #(list.append(state.0, results), new_pending, state.2)
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
}

pub type WorkerMessage {
  Check
}

fn checker(
  state: #(Int, Int, Int, process.Subject(BossMessage)),
  message: WorkerMessage,
) -> actor.Next(#(Int, Int, Int, process.Subject(BossMessage)), WorkerMessage) {
  case message {
    Check -> {
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
      actor.send(boss_subject, PostResults(result))
      actor.stop()
    }
  }
}
