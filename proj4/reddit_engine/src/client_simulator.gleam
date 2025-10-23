import gleam/erlang/charlist
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import models.{type PostId}
import reddit_engine

const total_users = 1000

// Rank subreddits by expected popularity
const subreddits_by_rank = [
  #("gaming", "Video games and gaming culture", 1),
  #("technology", "Latest in tech", 2),
  #("movies", "Movie discussions and reviews", 3),
  #("gleam", "Gleam programming language", 4),
  #("science", "Scientific discoveries", 5),
  #("functional", "Functional programming discussions", 6),
  #("erlang", "Erlang and BEAM ecosystem", 7),
  #("distributed", "Distributed systems", 8),
]

pub fn main() {
  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("       Reddit Engine Simulator")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
  io.println(
    "Simulating "
    <> int.to_string(total_users)
    <> " users with realistic behavior patterns\n",
  )

  reddit_engine.net_kernel_start(charlist.from_string("simulator"))
  reddit_engine.set_cookie("simulator", "secret")
  io.println("✓ Simulator node started")

  let server_node = "reddit_engine@Yashs-MacBook-Air.local"
  process.sleep(1000)
  let ping_result = reddit_engine.ping_erlang(charlist.from_string(server_node))

  case ping_result {
    reddit_engine.Pong -> {
      io.println("✓ Connected to " <> server_node)
      process.sleep(1000)

      case reddit_engine.whereis_global("reddit_engine") {
        Ok(engine_pid) -> {
          io.println("✓ Found reddit engine\n")

          // Start post tracking actor
          let post_tracker = start_post_tracker()

          run_simulation(engine_pid, "reddit_engine", post_tracker)
        }
        Error(_) -> {
          io.println("✗ Could not find reddit engine")
        }
      }
    }
    reddit_engine.Pang -> {
      io.println("✗ Failed to connect to server")
    }
  }
}

pub type PostTrackingMessage {
  AddPost(subreddit: String, post_id: PostId)
  GetRandomPost(reply_to: process.Subject(Result(#(String, PostId), Nil)))
}

// Actor to track posts across all users for voting/commenting
fn start_post_tracker() -> process.Subject(PostTrackingMessage) {
  let parent_subject = process.new_subject()

  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    // Send the subject back to parent
    process.send(parent_subject, subject)
    post_tracker_loop(subject, [])
  })

  // Wait for the subject from the spawned process
  let assert Ok(subject) = process.receive(parent_subject, 1000)
  subject
}

fn post_tracker_loop(
  subject: process.Subject(PostTrackingMessage),
  posts: List(#(String, PostId)),
) {
  case process.receive(subject, 10) {
    Ok(AddPost(subreddit, post_id)) -> {
      post_tracker_loop(subject, [#(subreddit, post_id), ..posts])
    }
    Ok(GetRandomPost(reply_to)) -> {
      let result = case list.shuffle(posts) |> list.first {
        Ok(post) -> Ok(post)
        Error(_) -> Error(Nil)
      }
      process.send(reply_to, result)
      post_tracker_loop(subject, posts)
    }
    Error(_) -> {
      // Timeout, continue
      post_tracker_loop(subject, posts)
    }
  }
}

fn run_simulation(
  engine_pid: process.Pid,
  server_node: String,
  post_tracker: process.Subject(PostTrackingMessage),
) {
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Phase 1: Setting up Subreddits")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Create subreddits
  list.each(subreddits_by_rank, fn(subreddit) {
    let #(name, desc, _) = subreddit
    send_message(
      engine_pid,
      server_node,
      reddit_engine.CreateSubreddit(name: name, description: desc),
    )
    io.println("✓ Created subreddit: " <> name)
  })
  io.println("")
  process.sleep(500)

  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Phase 2: Spawning User Actors")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  let completion_subject = process.new_subject()

  // Spawn user actors - each runs independently
  let user_pids =
    list.range(1, total_users)
    |> list.map(fn(i) {
      let username = "user" <> int.to_string(i)
      let is_power_user = i <= total_users / 10

      // Spawn each user as a separate process
      let user_pid =
        process.spawn_unlinked(fn() {
          simulate_user(
            engine_pid,
            server_node,
            username,
            is_power_user,
            post_tracker,
          )

          // Track completion
          process.send(completion_subject, username)
        })

      io.println("✓ Spawned user actor: " <> username)
      user_pid
    })

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println(
    "✓ Spawned " <> int.to_string(list.length(user_pids)) <> " user actors",
  )
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Let the simulation run for a while
  wait_for_completions(completion_subject, total_users, 0)

  // Report subreddit membership distribution
  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Subreddit Membership Distribution (Zipf)")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  report_membership_distribution(engine_pid, server_node)

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Simulation Complete!")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}

fn report_membership_distribution(engine_pid: process.Pid, server_node: String) {
  list.each(subreddits_by_rank, fn(subreddit) {
    let #(name, _, rank) = subreddit
    let reply_sub = process.new_subject()
    send_message(
      engine_pid,
      server_node,
      reddit_engine.GetSubredditMemberCount(
        subreddit_id: name,
        reply_to: reply_sub,
      ),
    )
    case process.receive(reply_sub, 1000) {
      Ok(count) -> {
        io.println(
          "Rank "
          <> int.to_string(rank)
          <> "  | r/"
          <> name
          <> "\t| Members: "
          <> int.to_string(count),
        )
      }
      Error(_) -> {
        io.println("Subreddit: " <> name <> " | Members: N/A")
      }
    }
  })
}

// Wait for all user actors to complete
fn wait_for_completions(
  subject: process.Subject(String),
  total: Int,
  count: Int,
) {
  case process.receive(subject, 120_000) {
    Ok(_username) -> {
      let new_count = count + 1
      case new_count >= total {
        True -> Nil
        False -> wait_for_completions(subject, total, new_count)
      }
    }
    Error(_) -> wait_for_completions(subject, total, count)
  }
}

// Each user actor runs this function independently
fn simulate_user(
  engine_pid: process.Pid,
  server_node: String,
  username: String,
  is_power_user: Bool,
  post_tracker: process.Subject(PostTrackingMessage),
) {
  // 1. Register the user
  send_message(
    engine_pid,
    server_node,
    reddit_engine.UserRegister(username: username),
  )
  process.sleep(int.random(100) + 50)

  // 2. Join subreddits
  let num_joins = case is_power_user {
    True -> 6 + int.random(3)
    // Power users join 6-8 subreddits
    False -> 2 + int.random(2)
    // Regular users join 2-3 subreddits
  }

  list.range(1, num_joins)
  |> list.each(fn(_) {
    let subreddit = pick_random_subreddit(is_power_user)
    send_message(
      engine_pid,
      server_node,
      reddit_engine.JoinSubreddit(username: username, subreddit_name: subreddit),
    )
    process.sleep(int.random(200) + 100)
  })

  // 3. Simulate online/offline cycles
  let cycles = case is_power_user {
    True -> 5 + int.random(5)
    // Power users: 5-10 cycles
    False -> 2 + int.random(3)
    // Regular users: 2-5 cycles
  }

  list.range(1, cycles)
  |> list.each(fn(cycle) {
    // User comes online
    let online_duration = case is_power_user {
      True -> 2000 + int.random(3000)
      // 2-5 seconds online
      False -> 1000 + int.random(2000)
      // 1-3 seconds online
    }
    io.println("... " <> username <> " going online ...")
    // Perform activities while online
    perform_online_activities(
      engine_pid,
      server_node,
      username,
      is_power_user,
      cycle,
      post_tracker,
    )

    // Stay online for a while
    process.sleep(online_duration)

    // User goes offline
    let offline_duration = int.random(1000) + 500
    io.println("... " <> username <> " going offline ...")
    // 0.5-1.5 seconds offline
    process.sleep(offline_duration)
  })

  io.println("✓ " <> username <> " completed simulation")
}

fn perform_online_activities(
  engine_pid: process.Pid,
  server_node: String,
  username: String,
  is_power_user: Bool,
  cycle: Int,
  post_tracker: process.Subject(PostTrackingMessage),
) {
  let num_activities = case is_power_user {
    True -> 3 + int.random(7)
    // Power users: 3-10 activities
    False -> 1 + int.random(3)
    // Regular users: 1-4 activities
  }

  list.range(1, num_activities)
  |> list.each(fn(activity_num) {
    let activity_type = int.random(10)

    case activity_type {
      // 30% Create a post
      0 | 1 | 2 -> {
        let subreddit = pick_random_subreddit(is_power_user)
        let is_repost = is_power_user && int.random(5) == 0

        let title = case is_repost {
          True -> "[REPOST] " <> generate_title(cycle * 100 + activity_num)
          False -> generate_title(cycle * 100 + activity_num)
        }

        // Create post and get response with post_id
        let reply_subject = process.new_subject()
        send_message(
          engine_pid,
          server_node,
          reddit_engine.CreatePostWithReply(
            username: username,
            subreddit_id: subreddit,
            title: title,
            content: generate_content(cycle * 100 + activity_num),
            reply_to: reply_subject,
          ),
        )

        // Wait for post_id response and track it
        case process.receive(reply_subject, 1000) {
          Ok(post_id) -> {
            process.send(post_tracker, AddPost(subreddit, post_id))
          }
          Error(_) -> Nil
        }

        process.sleep(int.random(300) + 100)
      }

      // 20% Comment on a post
      3 | 4 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 100) {
          Ok(Ok(#(subreddit, post_id))) -> {
            send_message(
              engine_pid,
              server_node,
              reddit_engine.CommentOnPost(
                username: username,
                subreddit_id: subreddit,
                post_id: post_id,
                content: "Great post! Here are my thoughts...",
              ),
            )
            process.sleep(int.random(200) + 50)
          }
          _ -> Nil
        }
      }

      // 20% Send direct message
      5 | 6 -> {
        let recipient = "user" <> int.to_string(int.random(total_users) + 1)

        send_message(
          engine_pid,
          server_node,
          reddit_engine.SendDirectMessage(
            from_username: username,
            to_username: recipient,
            content: "Hey! How are you doing?",
          ),
        )
        process.sleep(int.random(200) + 50)
      }

      // 20% Vote on posts
      7 | 8 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 100) {
          Ok(Ok(#(subreddit, post_id))) -> {
            let vote = case int.random(2) {
              0 -> models.Upvote
              _ -> models.Downvote
            }

            send_message(
              engine_pid,
              server_node,
              reddit_engine.VotePost(
                subreddit_id: subreddit,
                username: username,
                post_id: post_id,
                vote: vote,
              ),
            )
            process.sleep(int.random(100) + 50)
          }
          _ -> Nil
        }
      }

      // 10% Get their feed
      _ -> {
        let reply_subject = process.new_subject()
        send_message(
          engine_pid,
          server_node,
          reddit_engine.GetFeed(username: username, reply_to: reply_subject),
        )
        // Don't wait for reply, just fire and forget
        process.sleep(int.random(100) + 50)
      }
    }
  })
}

fn pick_random_subreddit(is_power_user: Bool) -> String {
  case is_power_user {
    // Power users follow Zipf distribution strictly
    True -> pick_subreddit_zipf()
    False -> {
      // Regular users: 70% Zipf, 30% uniform random
      case int.random(10) < 7 {
        True -> pick_subreddit_zipf()
        False ->
          list.shuffle(subreddits_by_rank)
          |> list.first
          |> fn(r) {
            case r {
              Ok(#(s, _, _)) -> s
              Error(_) -> "gleam"
            }
          }
      }
    }
  }
}

fn send_message(engine_pid: process.Pid, server_node: String, message: a) {
  reddit_engine.send_to_named_subject(engine_pid, server_node, message)
}

fn generate_title(index: Int) -> String {
  let titles = [
    "Check out this amazing feature!",
    "Discussion: Best practices for ",
    "Help needed with ",
    "TIL: Interesting fact about ",
    "Question about implementation",
    "Sharing my recent project",
    "Performance optimization tips",
    "New release announcement",
  ]

  list.shuffle(titles)
  |> list.first
  |> fn(r) {
    case r {
      Ok(t) -> t <> " #" <> int.to_string(index)
      Error(_) -> "Post #" <> int.to_string(index)
    }
  }
}

fn generate_content(index: Int) -> String {
  "This is the content for post #"
  <> int.to_string(index)
  <> ". Lorem ipsum dolor sit amet, consectetur adipiscing elit."
}

pub fn calculate_zipf_distribution() -> List(Float) {
  let ranks = list.range(1, list.length(subreddits_by_rank))
  // For each subreddit at rank r, the probability weight is 1/r.
  let weights = list.map(ranks, fn(rank) { 1.0 /. int.to_float(rank) })
  // Normalize weights
  let total = list.fold(weights, 0.0, fn(acc, w) { acc +. w })
  // Return normalized weights
  list.map(weights, fn(w) { w /. total })
}

fn pick_subreddit_zipf() -> String {
  let distribution = calculate_zipf_distribution()
  select_by_cumulative_probability(
    subreddits_by_rank,
    distribution,
    float.random(),
    0.0,
  )
}

fn select_by_cumulative_probability(
  subreddits: List(#(String, String, Int)),
  probabilities: List(Float),
  target: Float,
  cumulative: Float,
) -> String {
  case subreddits, probabilities {
    [], _ -> "gleam"
    // Default subreddit
    _, [] -> "gleam"
    // Default subreddit
    [#(name, _, _), ..rest_subs], [p, ..rest_probs] -> {
      let new_cumulative = cumulative +. p
      // Check if target falls within this cumulative range
      case target <=. new_cumulative {
        True -> name
        False ->
          select_by_cumulative_probability(
            rest_subs,
            rest_probs,
            target,
            new_cumulative,
          )
      }
    }
  }
}
