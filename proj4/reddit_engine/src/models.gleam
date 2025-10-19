import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}
import youid/uuid

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
    posts: List(Post),
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
    comments: List(Comment),
    upvote: Int,
    downvote: Int,
    timestamp: Timestamp,
  )
}

pub type Comment {
  Comment(
    id: CommentId,
    replies: List(Comment),
    content: String,
    author: Username,
    timestamp: Timestamp,
    upvote: Int,
    downvote: Int,
  )
}

pub type CommentId =
  uuid.Uuid

pub type PostId =
  uuid.Uuid
