import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/option
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}
import models.{
  type Comment, type DirectMessage, type Post, type PostId, type Subreddit,
  type SubredditId, type User, type Username,
}
import youid/uuid

pub fn main() -> Nil {
  io.println("Hello from reddit_engine!")

  let assert Ok(engine_actor) =
    actor.new_with_initialiser(1000, fn(self_sub) {
      // Initial node state for the Chord node
      EngineState(
        self_subject: self_sub,
        users: dict.new(),
        subreddits: dict.new(),
      )
      |> actor.initialised
      |> actor.returning(self_sub)
      |> Ok
    })
    |> actor.on_message(engine_message_handler)
    |> actor.start

  echo timestamp.system_time()
  echo uuid.v4()
  Nil
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

    CommentOnPost(username:, post_id:, content:) ->
      actor.continue(comment_on_post(state, username, post_id, content))
  }
}

pub type EngineMessage {
  UserRegister(username: Username)
  CreateSubreddit(name: SubredditId, description: String)
  JoinSubreddit(username: Username, subreddit_name: SubredditId)
  LeaveSubreddit(username: Username, subreddit_name: SubredditId)
  CommentOnPost(username: Username, post_id: PostId, content: String)
}

pub type EngineState {
  EngineState(
    self_subject: process.Subject(EngineMessage),
    users: Dict(Username, User),
    subreddits: Dict(SubredditId, Subreddit),
  )
}

pub fn comment_on_post(
  state: EngineState,
  username: Username,
  post_id: PostId,
  content: String,
) -> EngineState {
  todo
}

pub fn leave_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
) -> EngineState {
  let updated_users =
    dict.upsert(state.users, username, fn(user_op) {
      case user_op {
        option.Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.delete(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        option.None -> panic as "User not found"
      }
    })

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        option.Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.delete(subreddit.subscribers, username),
          )

        option.None -> panic as "Subreddit not found"
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
        option.Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.insert(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        option.None -> panic as "User not found"
      }
    })

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        option.Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.insert(subreddit.subscribers, username),
          )

        option.None -> panic as "Subreddit not found"
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
