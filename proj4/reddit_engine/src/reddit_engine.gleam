import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/set
import gleam/time/timestamp
import models.{
  type CommentId, type DirectMessage, type Post, type PostId, type Subreddit,
  type SubredditId, type User, type Username, type VoteType, Downvote, Upvote,
}

pub fn main() -> Nil {
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("       Reddit Engine Starting Up")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Create a static name from atom for consistent distributed addressing
  let engine_name = atom_to_name(atom.create("reddit_engine"))

  // Initialize and start the actor with named subject
  let assert Ok(engine_actor) =
    actor.new_with_initialiser(1000, fn(self_sub) {
      EngineState(
        self_subject: self_sub,
        users: dict.new(),
        subreddits: dict.new(),
      )
      |> actor.initialised
      |> actor.returning(self_sub)
      |> Ok
    })
    |> actor.named(engine_name)
    |> actor.on_message(engine_message_handler)
    |> actor.start

  io.println("✓ Reddit engine actor started")

  // Start distributed Erlang with longnames
  net_kernel_start(charlist.from_string("reddit_engine"))
  set_cookie("reddit_engine", "secret")
  io.println("✓ Started distributed Erlang node")

  // Register globally so it's accessible from other nodes
  let global_reg_result = register_global("reddit_engine", engine_actor.pid)
  case global_reg_result {
    Ok(_) -> io.println("✓ Reddit engine registered globally!")
    Error(msg) -> io.println("✗ Global registration failed: " <> msg)
  }

  io.print("\nGlobal names: ")
  echo list_global_names()

  io.println("\nConnected nodes:")
  echo list_nodes()

  io.println("\nCurrent cookie:")
  echo get_cookie_erlang()

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("  Engine ready - waiting for messages")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  process.sleep_forever()
  Nil
}

pub type EngineState {
  EngineState(
    self_subject: process.Subject(EngineMessage),
    users: Dict(Username, User),
    subreddits: Dict(SubredditId, Subreddit),
  )
}

pub type EngineMessage {
  UserRegister(username: Username)
  CreateSubreddit(name: SubredditId, description: String)
  JoinSubreddit(username: Username, subreddit_name: SubredditId)
  LeaveSubreddit(username: Username, subreddit_name: SubredditId)
  CreatePostWithReply(
    username: Username,
    subreddit_id: SubredditId,
    content: String,
    title: String,
    reply_to: process.Subject(PostId),
  )
  CommentOnPost(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    content: String,
  )
  CommentOnComment(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    parent_comment_id: CommentId,
    content: String,
  )
  VotePost(
    subreddit_id: SubredditId,
    username: Username,
    post_id: PostId,
    vote: VoteType,
  )
  GetFeed(username: Username, reply_to: process.Subject(List(Post)))
  GetDirectMessages(
    username: Username,
    reply_to: process.Subject(List(DirectMessage)),
  )
  SendDirectMessage(
    from_username: Username,
    to_username: Username,
    content: String,
  )
  GetKarma(
    sender_username: Username,
    username: Username,
    reply_to: process.Subject(Int),
  )
  GetSubredditMemberCount(
    subreddit_id: SubredditId,
    reply_to: process.Subject(Int),
  )
}

pub fn engine_message_handler(
  state: EngineState,
  message: EngineMessage,
) -> actor.Next(EngineState, EngineMessage) {
  // Route incoming messages to appropriate handler functions
  case message {
    UserRegister(username:) -> actor.continue(register_user(state, username))
    CreateSubreddit(name:, description:) ->
      actor.continue(create_subreddit(state, name, description))
    JoinSubreddit(username:, subreddit_name:) ->
      actor.continue(join_subreddit(state, username, subreddit_name))
    LeaveSubreddit(username:, subreddit_name:) ->
      actor.continue(leave_subreddit(state, username, subreddit_name))
    CommentOnPost(username:, subreddit_id:, post_id:, content:) ->
      actor.continue(comment_on_post(
        state,
        username,
        subreddit_id,
        post_id,
        content,
      ))
    CommentOnComment(
      username: username,
      subreddit_id: subreddit_id,
      post_id: post_id,
      parent_comment_id: parent_comment_id,
      content: content,
    ) ->
      actor.continue(comment_on_comment(
        state,
        username,
        subreddit_id,
        post_id,
        parent_comment_id,
        content,
      ))
    GetFeed(username:, reply_to:) ->
      actor.continue(get_feed(state, username, reply_to))
    GetDirectMessages(username:, reply_to:) ->
      actor.continue(get_direct_messages(state, username, reply_to))
    SendDirectMessage(
      from_username: from_username,
      to_username: to_username,
      content: content,
    ) ->
      actor.continue(send_direct_message(
        state,
        from_username,
        to_username,
        content,
      ))
    CreatePostWithReply(username:, subreddit_id:, content:, title:, reply_to:) ->
      actor.continue(create_post_with_reply(
        state,
        username,
        subreddit_id,
        content,
        title,
        reply_to,
      ))
    VotePost(subreddit_id:, username:, post_id:, vote:) ->
      actor.continue(vote_post(state, username, subreddit_id, post_id, vote))
    GetKarma(sender_username:, username:, reply_to:) ->
      actor.continue(get_karma(state, sender_username, username, reply_to))
    GetSubredditMemberCount(subreddit_id:, reply_to:) ->
      actor.continue(get_subreddit_member_count(state, subreddit_id, reply_to))
  }
}

pub fn get_subreddit_member_count(
  state: EngineState,
  subreddit_id: SubredditId,
  reply_to: process.Subject(Int),
) -> EngineState {
  io.println("Requesting member count for r/" <> subreddit_id)
  // Retrieve subreddit and count subscribers
  let member_count = case dict.get(state.subreddits, subreddit_id) {
    Ok(subreddit) -> set.size(subreddit.subscribers)
    Error(_) -> 0
  }
  process.send(reply_to, member_count)
  state
}

pub fn get_karma(
  state: EngineState,
  sender_username: Username,
  username: Username,
  reply_to: process.Subject(Int),
) -> EngineState {
  io.println(sender_username <> " is requesting karma for " <> username)
  // Retrieve user's upvotes and downvotes
  let user_upvotes =
    case dict.get(state.users, username) {
      Ok(user) -> user.upvotes
      Error(_) -> 0
    }
    |> int.to_float
  let user_downvotes =
    case dict.get(state.users, username) {
      Ok(user) -> user.downvotes
      Error(_) -> 0
    }
    |> int.to_float
  // Calculate karma based on upvotes and downvotes
  let karma = user_upvotes *. 1.2 -. user_downvotes *. 0.7 |> float.round
  process.send(reply_to, karma)
  state
}

pub fn vote_post(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  vote: VoteType,
) -> EngineState {
  io.println(username <> " is voting in r/" <> subreddit_id)

  // Check if subreddit exists
  case dict.get(state.subreddits, subreddit_id) {
    Error(_) -> {
      io.println("⚠ Subreddit r/" <> subreddit_id <> " not found for voting")
      state
    }
    Ok(subreddit) -> {
      // Find the post to vote on
      let post_opt = list.find(subreddit.posts, fn(post) { post.id == post_id })

      case post_opt {
        Error(_) -> {
          io.println("⚠ Post not found in r/" <> subreddit_id <> " for voting")
          state
        }
        Ok(found_post) -> {
          // Update the post's upvote/downvote count in the subreddit
          let updated_subreddits =
            dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
              case sub_op {
                Some(subreddit) -> {
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True ->
                          case vote {
                            Upvote ->
                              models.Post(..post, upvote: post.upvote + 1)
                            Downvote ->
                              models.Post(..post, downvote: post.downvote + 1)
                          }
                        False -> post
                      }
                    })
                  models.Subreddit(..subreddit, posts: updated_posts)
                }
                None -> subreddit
              }
            })

          // Update the author's karma (upvote/downvote count)
          let updated_users = case dict.get(state.users, found_post.author) {
            Ok(_) -> {
              dict.upsert(state.users, found_post.author, fn(user_op) {
                case user_op {
                  Some(user) ->
                    case vote {
                      Upvote -> models.User(..user, upvotes: user.upvotes + 1)
                      Downvote ->
                        models.User(..user, downvotes: user.downvotes + 1)
                    }
                  None ->
                    user_op
                    |> option.unwrap(
                      models.User(
                        username: found_post.author,
                        upvotes: 0,
                        downvotes: 0,
                        subscribed_subreddits: set.new(),
                        inbox: [],
                      ),
                    )
                }
              })
            }
            Error(_) -> {
              io.println("⚠ Post author " <> found_post.author <> " not found")
              state.users
            }
          }

          EngineState(
            ..state,
            subreddits: updated_subreddits,
            users: updated_users,
          )
        }
      }
    }
  }
}

pub fn create_post_with_reply(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  content: String,
  title: String,
  reply_to: process.Subject(PostId),
) -> EngineState {
  io.println(username <> " is creating post in r/" <> subreddit_id)

  // Generate a unique ID and create the new post
  let new_post =
    models.Post(
      id: models.uuid_gen(),
      title: title,
      content: content,
      author: username,
      comments: dict.new(),
      upvote: 0,
      downvote: 0,
      timestamp: timestamp.system_time(),
    )

  // Send the post_id back to the requester
  process.send(reply_to, new_post.id)

  // Add the post to the subreddit
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(subreddit_op) {
      case subreddit_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            posts: list.prepend(subreddit.posts, new_post),
          )
        None -> {
          io.println(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for post creation",
          )
          models.Subreddit(
            name: subreddit_id,
            description: "",
            subscribers: set.new(),
            posts: [new_post],
          )
        }
      }
    })

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn send_direct_message(
  state: EngineState,
  from_username: Username,
  to_username: Username,
  content: String,
) -> EngineState {
  io.println(from_username <> " is sending DM to " <> to_username)

  // Create the message with timestamp
  let new_message =
    models.DirectMessage(
      from: from_username,
      to: to_username,
      content: content,
      timestamp: timestamp.system_time(),
    )

  // Add message to recipient's inbox
  let updated_users = case dict.get(state.users, to_username) {
    Ok(_) -> {
      dict.upsert(state.users, to_username, fn(user_op) {
        let assert Some(user) = user_op
        models.User(..user, inbox: list.prepend(user.inbox, new_message))
      })
    }
    Error(_) -> {
      io.println("⚠ Recipient user " <> to_username <> " not found")
      state.users
    }
  }

  EngineState(..state, users: updated_users)
}

pub fn get_direct_messages(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(List(DirectMessage)),
) -> EngineState {
  io.println(username <> " is fetching their direct messages")

  // Retrieve user's inbox
  let user_inbox = case dict.get(state.users, username) {
    Ok(user) -> user.inbox
    Error(_) -> {
      io.println("⚠ User " <> username <> " not found for fetching messages")
      []
    }
  }

  // Send inbox to the requesting subject
  actor.send(reply_to, user_inbox)

  state
}

pub fn get_feed(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(List(Post)),
) -> EngineState {
  io.println(username <> " is requesting their feed")

  // Get user's subscribed subreddits
  let subscribed_subreddits = case dict.get(state.users, username) {
    Ok(user) -> user.subscribed_subreddits
    Error(_) -> {
      io.println("⚠ User " <> username <> " not found for feed request")
      set.new()
    }
  }

  // Aggregate posts from subscribed subreddits (top 5 from each)
  let feed_posts =
    subscribed_subreddits
    |> set.to_list
    |> list.map(fn(subreddit_id) {
      case dict.get(state.subreddits, subreddit_id) {
        Ok(subreddit) -> subreddit.posts |> list.take(5)
        Error(_) -> []
      }
    })
    |> list.flatten

  // Send the aggregated feed to the requesting subject
  process.send(reply_to, feed_posts)

  state
}

pub fn comment_on_comment(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  parent_comment_id: CommentId,
  content: String,
) -> EngineState {
  io.println(username <> " is replying to a comment in r/" <> subreddit_id)

  // Create nested comment with parent reference
  let new_comment =
    models.Comment(
      id: models.uuid_gen(),
      author: username,
      content: content,
      timestamp: timestamp.system_time(),
      upvote: 0,
      downvote: 0,
      parent_id: Some(parent_comment_id),
    )

  // Add comment to the post in the subreddit
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                False -> post
                True -> {
                  case dict.has_key(post.comments, parent_comment_id) {
                    False -> {
                      io.println("⚠ Parent comment not found in post")
                      post
                    }
                    True ->
                      models.Post(
                        ..post,
                        comments: dict.insert(
                          post.comments,
                          new_comment.id,
                          new_comment,
                        ),
                      )
                  }
                }
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> {
          io.println(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for commenting",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_id,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn comment_on_post(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  content: String,
) -> EngineState {
  io.println(username <> " is commenting on a post in r/" <> subreddit_id)

  // Create top-level comment (no parent)
  let new_comment =
    models.Comment(
      id: models.uuid_gen(),
      author: username,
      content: content,
      timestamp: timestamp.system_time(),
      upvote: 0,
      downvote: 0,
      parent_id: None,
    )

  // Add comment to the post
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                False -> post
                True ->
                  models.Post(
                    ..post,
                    comments: dict.insert(
                      post.comments,
                      new_comment.id,
                      new_comment,
                    ),
                  )
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> {
          io.println(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for commenting",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_id,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn leave_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
) -> EngineState {
  io.println(username <> " is leaving subreddit " <> subreddit_name)
  let updated_users =
    dict.upsert(state.users, username, fn(user_op) {
      case user_op {
        Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.delete(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        None -> {
          io.println(
            "⚠ User " <> username <> " not found for leaving subreddit",
          )
          user_op
          |> option.unwrap(
            models.User(
              username: username,
              upvotes: 0,
              downvotes: 0,
              subscribed_subreddits: set.new(),
              inbox: [],
            ),
          )
        }
      }
    })

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.delete(subreddit.subscribers, username),
          )

        None -> {
          io.println(
            "⚠ Subreddit r/" <> subreddit_name <> " not found for leaving",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_name,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn join_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
) -> EngineState {
  io.println(username <> " is joining r/" <> subreddit_name)

  // Add subreddit to user's subscriptions
  let updated_users =
    dict.upsert(state.users, username, fn(user_op) {
      case user_op {
        Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.insert(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        None -> {
          io.println(
            "⚠ User " <> username <> " not found for joining subreddit",
          )
          user_op
          |> option.unwrap(
            models.User(
              username: username,
              upvotes: 0,
              downvotes: 0,
              subscribed_subreddits: set.from_list([subreddit_name]),
              inbox: [],
            ),
          )
        }
      }
    })

  // Add user to subreddit's subscriber list
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.insert(subreddit.subscribers, username),
          )

        None -> {
          io.println(
            "⚠ Subreddit r/" <> subreddit_name <> " not found for joining",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_name,
              description: "",
              subscribers: set.from_list([username]),
              posts: [],
            ),
          )
        }
      }
    })

  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn create_subreddit(
  state: EngineState,
  name: SubredditId,
  description: String,
) -> EngineState {
  // Create new subreddit with empty subscriber list and posts
  let new_subreddit =
    models.Subreddit(
      name: name,
      description: description,
      subscribers: set.new(),
      posts: [],
    )

  // Check if subreddit already exists to avoid duplicates
  let updated_subreddits = case dict.get(state.subreddits, name) {
    Ok(_) -> {
      io.println("⚠ Subreddit r/" <> name <> " already exists")
      state.subreddits
    }

    Error(_) -> {
      io.println("✓ Created subreddit r/" <> name)
      dict.insert(state.subreddits, name, new_subreddit)
    }
  }

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn register_user(state: EngineState, username: Username) -> EngineState {
  // Create new user with default values
  let new_user =
    models.User(
      username: username,
      upvotes: 0,
      downvotes: 0,
      subscribed_subreddits: set.new(),
      inbox: [],
    )

  // Check if user already exists to avoid duplicate registrations
  let updated_users = case dict.has_key(state.users, username) {
    True -> {
      io.println("⚠ User " <> username <> " already registered")
      state.users
    }
    False -> {
      io.println("✓ User " <> username <> " registered successfully")
      dict.insert(state.users, username, new_user)
    }
  }

  EngineState(
    self_subject: state.self_subject,
    users: updated_users,
    subreddits: state.subreddits,
  )
}

// ═══════════════════════════════════════════════════════
// Distributed Erlang FFI Functions
// ═══════════════════════════════════════════════════════

// Convert atom to Name for static naming (no random suffix)
@external(erlang, "distr", "atom_to_name")
fn atom_to_name(atom: atom.Atom) -> process.Name(message)

// Start distributed Erlang with longnames
@external(erlang, "distr", "start_short")
pub fn net_kernel_start(name: Charlist) -> Bool

// Set Erlang cookie for node authentication
@external(erlang, "distr", "set_cookie_erlang")
fn set_cookie_erlang(name: Charlist, cookie: Charlist) -> Bool

// Get current Erlang cookie
@external(erlang, "distr", "get_cookie")
pub fn get_cookie_erlang() -> Charlist

// Ping a remote node to check connectivity
@external(erlang, "distr", "ping")
pub fn ping_erlang(name: Charlist) -> PingResponse

pub type PingResponse {
  Pong
  Pang
}

// Find a process registered on a remote node
@external(erlang, "distr", "whereis_remote")
fn whereis_remote_erlang(
  registered_name: Charlist,
  node_name: Charlist,
) -> Result(process.Pid, atom.Atom)

// Register a process in the global registry
@external(erlang, "distr", "register_global")
fn register_global_erlang(
  name: Charlist,
  pid: process.Pid,
) -> Result(atom.Atom, atom.Atom)

// Find a process in the global registry
@external(erlang, "distr", "whereis_global")
fn whereis_global_erlang(name: Charlist) -> Result(process.Pid, atom.Atom)

// Send message to a named subject on a remote node
@external(erlang, "distr", "send_to_named_subject")
fn send_to_named_subject_erlang(
  pid: process.Pid,
  registered_name: Charlist,
  message: a,
) -> atom.Atom

// List all connected nodes
@external(erlang, "distr", "list_nodes")
fn list_nodes_erlang() -> List(atom.Atom)

// List all globally registered process names
@external(erlang, "distr", "list_global_names")
fn list_global_names_erlang() -> List(atom.Atom)

// ═══════════════════════════════════════════════════════
// Public Wrapper Functions
// ═══════════════════════════════════════════════════════

pub fn register_global(name: String, pid: process.Pid) -> Result(Nil, String) {
  case register_global_erlang(charlist.from_string(name), pid) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("Failed to register process globally")
  }
}

pub fn whereis_global(name: String) -> Result(process.Pid, String) {
  case whereis_global_erlang(charlist.from_string(name)) {
    Ok(pid) -> Ok(pid)
    Error(_) -> Error("Process not found in global registry")
  }
}

pub fn list_nodes() -> List(atom.Atom) {
  list_nodes_erlang()
}

pub fn list_global_names() -> List(atom.Atom) {
  list_global_names_erlang()
}

pub fn whereis_remote(
  registered_name: String,
  node_name: String,
) -> Result(process.Pid, String) {
  case
    whereis_remote_erlang(
      charlist.from_string(registered_name),
      charlist.from_string(node_name),
    )
  {
    Ok(pid) -> Ok(pid)
    Error(_) -> Error("Process not found on remote node")
  }
}

pub fn send_to_named_subject(
  pid: process.Pid,
  registered_name: String,
  message: a,
) -> Nil {
  send_to_named_subject_erlang(
    pid,
    charlist.from_string(registered_name),
    message,
  )
  Nil
}

pub fn set_cookie(nodename: String, cookie: String) {
  set_cookie_erlang(
    charlist.from_string(nodename),
    charlist.from_string(cookie),
  )
}
