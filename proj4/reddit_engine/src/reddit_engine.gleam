import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}
import models.{
  type Comment, type CommentId, type DirectMessage, type Post, type PostId,
  type Subreddit, type SubredditId, type User, type Username, type VoteType,
}

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
  echo models.uuid_gen()
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

    GetFeed(username:) -> actor.continue(get_feed(state, username))

    _ -> actor.continue(state)
  }
}

pub type EngineMessage {
  UserRegister(username: Username)
  CreateSubreddit(name: SubredditId, description: String)
  JoinSubreddit(username: Username, subreddit_name: SubredditId)
  LeaveSubreddit(username: Username, subreddit_name: SubredditId)
  CreatePost(username: Username, subreddit_id: SubredditId, content: String)
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
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    vote: VoteType,
  )
  GetFeed(username: Username)
  GetDirectMessages(username: Username)
  SendDirectMessage(
    from_username: Username,
    to_username: Username,
    content: String,
  )
}

pub type EngineState {
  EngineState(
    self_subject: process.Subject(EngineMessage),
    users: Dict(Username, User),
    subreddits: Dict(SubredditId, Subreddit),
  )
}

pub fn get_feed(state: EngineState, username: Username) -> EngineState {
  // let subscribed_subreddits = case dict.get(state.users, username) {
  //   Some(user) -> user.subscribed_subreddits
  //   None -> panic as "get_feed: User not found"
  // }
  // let feed_posts = subscribed_subreddits |> set.to_list
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
            dict.upsert(subreddit.posts, post_id, fn(post_op) {
              case post_op {
                Some(post) -> {
                  case dict.has_key(post.comments, parent_comment_id) {
                    True -> {
                      let updated_comments =
                        dict.insert(post.comments, new_comment.id, new_comment)
                      models.Post(..post, comments: updated_comments)
                    }
                    False ->
                      panic as "comment_on_comment: Parent comment not found"
                  }
                }

                None -> panic as "comment_on_comment: Post not found"
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
            dict.upsert(subreddit.posts, post_id, fn(post_op) {
              case post_op {
                Some(post) -> {
                  let updated_comments =
                    dict.insert(post.comments, new_comment.id, new_comment)
                  models.Post(..post, comments: updated_comments)
                }

                None -> panic as "comment_on_post: Post not found"
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
      posts: dict.new(),
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
