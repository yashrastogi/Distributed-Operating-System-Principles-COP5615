import gleam/list

pub type Tree {
  Nil
  Node(data: Int, left: Tree, right: Tree)
}

pub fn to_tree(data: List(Int)) -> Tree {
  build_tree(data, Nil)
}

pub fn sorted_data(data: List(Int)) -> List(Int) {
  data
  |> to_tree()
  |> sort_tree()
}

fn build_tree(data: List(Int), tree: Tree) -> Tree {
  case data {
    [] -> tree
    [head, ..tail] -> build_tree(tail, insert(tree, head))
  }
}

fn insert(tree: Tree, value: Int) -> Tree {
  case tree {
    Nil -> Node(value, Nil, Nil)
    Node(data, left, right) if value <= data ->
      Node(data, insert(left, value), right)
    Node(data, left, right) -> Node(data, left, insert(right, value))
  }
}

fn sort_tree(tree: Tree) -> List(Int) {
  case tree {
    Nil -> []
    Node(data, left, right) ->
      list.flatten([sort_tree(left), [data], sort_tree(right)])
  }
}
