import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
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
  io.println("Hello from reddit_engine!")

  let engine_name = atom_to_name(atom.create("reddit_engine"))
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

  // Start distributed Erlang
  net_kernel_start(charlist.from_string("reddit_engine"))
  set_cookie("reddit_engine", "secret")
  io.println("Started distributed Erlang node")

  // Register globally so it's accessible from other nodes
  let global_reg_result = register_global("reddit_engine", engine_actor.pid)
  case global_reg_result {
    Ok(_) -> io.println("Reddit engine registered globally!")
    Error(msg) -> io.println("Global registration failed: " <> msg)
  }

  io.print("Global names: ")
  echo list_global_names()

  io.println("\nConnected nodes:")
  echo list_nodes()
  io.println("\nCurrent cookie:")
  echo get_cookie_erlang()

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
  CreatePost(
    username: Username,
    subreddit_id: SubredditId,
    content: String,
    title: String,
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
  VotePost(subreddit_id: SubredditId, post_id: PostId, vote: VoteType)
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
}

pub fn engine_message_handler(
  state: EngineState,
  message: EngineMessage,
) -> actor.Next(EngineState, EngineMessage) {
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
    CreatePost(username:, subreddit_id:, content:, title:) ->
      actor.continue(create_post(state, username, subreddit_id, content, title))
    VotePost(subreddit_id:, post_id:, vote:) ->
      actor.continue(vote_post(state, subreddit_id, post_id, vote))
  }
}

pub fn vote_post(
  state: EngineState,
  subreddit_id: SubredditId,
  post_id: PostId,
  vote: VoteType,
) -> EngineState {
  // Update the post's upvote/downvote count
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                True ->
                  case vote {
                    Upvote -> models.Post(..post, upvote: post.upvote + 1)
                    Downvote -> models.Post(..post, downvote: post.downvote + 1)
                  }

                False -> post
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> panic as "vote_post: Subreddit not found"
      }
    })

  let post_author = case dict.get(state.subreddits, subreddit_id) {
    Ok(subreddit) -> {
      let post_opt = list.find(subreddit.posts, fn(post) { post.id == post_id })

      case post_opt {
        Ok(post) -> post.author
        Error(_) -> panic as "vote_post: Post not found"
      }
    }
    Error(_) -> panic as "vote_post: Subreddit not found"
  }

  // Update the author's upvote/downvote count
  let updated_users =
    dict.upsert(state.users, post_author, fn(user_op) {
      case user_op {
        Some(user) ->
          case vote {
            Upvote -> models.User(..user, upvotes: user.upvotes + 1)
            Downvote -> models.User(..user, downvotes: user.downvotes + 1)
          }

        None -> panic as "vote_post: Post author user not found"
      }
    })

  EngineState(..state, subreddits: updated_subreddits, users: updated_users)
}

pub fn create_post(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  content: String,
  title: String,
) -> EngineState {
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

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(subreddit_op) {
      case subreddit_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            posts: list.prepend(subreddit.posts, new_post),
          )
        None -> panic as "create_post: Subreddit not found"
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
  let new_message =
    models.DirectMessage(
      from: from_username,
      to: to_username,
      content: content,
      timestamp: timestamp.system_time(),
    )

  let updated_users =
    dict.upsert(state.users, to_username, fn(user_op) {
      case user_op {
        Some(user) ->
          models.User(..user, inbox: list.prepend(user.inbox, new_message))

        None -> panic as "send_direct_message: Recipient user not found"
      }
    })

  EngineState(..state, users: updated_users)
}

pub fn get_direct_messages(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(List(DirectMessage)),
) -> EngineState {
  let user_inbox = case dict.get(state.users, username) {
    Ok(user) -> user.inbox
    Error(_) -> panic as "get_direct_messages: User not found"
  }

  actor.send(reply_to, user_inbox)

  state
}

pub fn get_feed(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(List(Post)),
) -> EngineState {
  let subscribed_subreddits = case dict.get(state.users, username) {
    Ok(user) -> user.subscribed_subreddits
    Error(_) -> panic as "get_feed: User not found"
  }

  let feed_posts =
    subscribed_subreddits
    |> set.to_list
    |> list.map(fn(subreddit_id) {
      case dict.get(state.subreddits, subreddit_id) {
        Ok(subreddit) -> subreddit.posts |> list.take(5)
        // Take last 5 posts from each subreddit
        Error(_) -> []
      }
    })
    |> list.flatten

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

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                False -> panic as "comment_on_comment: Post not found"
                True -> {
                  case dict.has_key(post.comments, parent_comment_id) {
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
                }
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> panic as "comment_on_comment: Subreddit not found"
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

        None -> panic as "comment_on_post: Subreddit not found"
      }
    })

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn leave_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
) -> EngineState {
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

        None -> panic as "leave_subreddit: User not found"
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

        None -> panic as "leave_subreddit: Subreddit not found"
      }
    })

  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn join_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
) -> EngineState {
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

        None -> panic as "join_subreddit: User not found"
      }
    })

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.insert(subreddit.subscribers, username),
          )

        None -> panic as "join_subreddit: Subreddit not found"
      }
    })

  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn create_subreddit(
  state: EngineState,
  name: SubredditId,
  description: String,
) -> EngineState {
  let new_subreddit =
    models.Subreddit(
      name: name,
      description: description,
      subscribers: set.new(),
      posts: [],
    )

  let updated_subreddits = dict.insert(state.subreddits, name, new_subreddit)

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn register_user(state: EngineState, username: Username) -> EngineState {
  io.println("Registering user: " <> username)
  let new_user =
    models.User(
      username: username,
      upvotes: 0,
      downvotes: 0,
      subscribed_subreddits: set.new(),
      inbox: [],
    )

  let updated_users = dict.insert(state.users, username, new_user)

  EngineState(
    self_subject: state.self_subject,
    users: updated_users,
    subreddits: state.subreddits,
  )
}

@external(erlang, "distr", "atom_to_name")
fn atom_to_name(atom: atom.Atom) -> process.Name(message)

@external(erlang, "distr", "start_short")
pub fn net_kernel_start(name: Charlist) -> Bool

@external(erlang, "distr", "set_cookie_erlang")
fn set_cookie_erlang(name: Charlist, cookie: Charlist) -> Bool

@external(erlang, "distr", "get_cookie")
pub fn get_cookie_erlang() -> Charlist

@external(erlang, "distr", "ping")
pub fn ping_erlang(name: Charlist) -> PingResponse

pub type PingResponse {
  Pong
  Pang
}

@external(erlang, "distr", "whereis_remote")
fn whereis_remote_erlang(
  registered_name: Charlist,
  node_name: Charlist,
) -> Result(process.Pid, atom.Atom)

@external(erlang, "distr", "register_global")
fn register_global_erlang(
  name: Charlist,
  pid: process.Pid,
) -> Result(atom.Atom, atom.Atom)

@external(erlang, "distr", "whereis_global")
fn whereis_global_erlang(name: Charlist) -> Result(process.Pid, atom.Atom)

@external(erlang, "distr", "send_to_named_subject")
fn send_to_named_subject_erlang(
  pid: process.Pid,
  registered_name: Charlist,
  message: a,
) -> atom.Atom

@external(erlang, "distr", "list_nodes")
fn list_nodes_erlang() -> List(atom.Atom)

@external(erlang, "distr", "list_global_names")
fn list_global_names_erlang() -> List(atom.Atom)

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
