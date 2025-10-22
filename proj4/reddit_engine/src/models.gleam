import gleam/crypto
import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}

pub type User {
  User(
    username: Username,
    upvotes: Int,
    downvotes: Int,
    subscribed_subreddits: Set(SubredditId),
    inbox: List(DirectMessage),
  )
}

pub type Username =
  String

pub type DirectMessage {
  DirectMessage(
    from: Username,
    to: Username,
    content: String,
    timestamp: Timestamp,
  )
}

pub type Subreddit {
  Subreddit(
    name: SubredditId,
    description: String,
    subscribers: Set(Username),
    posts: Dict(PostId, Post),
  )
}

pub type SubredditId =
  String

pub type Post {
  Post(
    id: PostId,
    title: String,
    content: String,
    author: Username,
    comments: Dict(CommentId, Comment),
    upvote: Int,
    downvote: Int,
    timestamp: Timestamp,
  )
}

pub type Comment {
  Comment(
    id: CommentId,
    content: String,
    parent_id: Option(CommentId),
    author: Username,
    timestamp: Timestamp,
    upvote: Int,
    downvote: Int,
  )
}

pub type CommentId =
  Uuid

pub type PostId =
  Uuid

pub type VoteType {
  Upvote
  Downvote
}

pub fn uuid_gen() -> Uuid {
  let assert <<a:size(48), _:size(4), b:size(12), _:size(2), c:size(62)>> =
    crypto.strong_random_bytes(16)

  let value = <<a:size(48), 4:size(4), b:size(12), 2:size(2), c:size(62)>>

  Uuid(value: value)
}

pub opaque type Uuid {
  Uuid(value: BitArray)
}
