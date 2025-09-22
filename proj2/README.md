# Distributed Algorithm Simulator

This project is a simulator for distributed algorithms, developed for the Distributed Operating System Principles course (COP5615). It implements and analyzes the performance of the Gossip and Push-Sum algorithms across various network topologies.

## Features

- **Distributed Algorithms:**
  - **Gossip:** For rumor propagation.
  - **Push-Sum:** For calculating aggregate values across the network.
- **Network Topologies:**
  - **Line:** A simple linear chain of nodes.
  - **3D Grid:** Nodes arranged in a three-dimensional cube.
  - **Imperfect 3D Grid:** A 3D grid with additional random connections.
  - **Full Mesh:** Every node is connected to every other node.
- **Configurable Parameters:**
  - Network size (number of nodes).
  - Choice of algorithm and topology.
- **Failure Simulation:**
  - Ability to simulate node failure by killing a specified percentage of nodes at the start.
  - A configurable probability for nodes to fail during message passing.

## Tech Stack

- **Programming Language:** [Gleam](https://gleam.run/)
- **Concurrency:** [gleam_otp](https://hex.pm/packages/gleam_otp) for the actor model implementation.
- **Time Measurement:** [birl](https://hex.pm/packages/birl) for precise performance timing.
- **Data Analysis:** Python for scripting data collection from simulation runs.

## Getting Started

### Prerequisites

- **Gleam:** Ensure you have Gleam installed. You can find installation instructions on the [official Gleam website](https://gleam.run/getting-started/installing/).
- **Erlang/OTP:** Gleam compiles to Erlang, so you will need the Erlang OTP installed.

### Installation & Setup

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd Distributed-Operating-System-Principles-COP5615-/proj2
    ```

2.  **Fetch dependencies:**
    ```bash
    gleam deps download
    ```

## Usage

You can run the simulation using the `gleam run` command, providing the required parameters.

### Command Syntax

```bash
gleam run <num_nodes> <topology> <algorithm> <kill_percent>
```

### Parameters

- `num_nodes`: (Integer) The total number of nodes in the network.
- `topology`: (String) The network structure. Options: `line`, `3d`, `imp3d`, `full`.
- `algorithm`: (String) The algorithm to simulate. Options: `gossip`, `push-sum`.
- `kill_percent`: (Integer) The percentage of nodes to kill at the start of the simulation (0-100).

### Example

To run a simulation with 1000 nodes in a 3D grid using the push-sum algorithm and a 10% node failure rate:

```bash
gleam run 1000 3d push-sum 10
```

## Data Collection

The project includes a Python script to automate running simulations and collecting performance data.

### How to Run

Execute the script from the project root:

```bash
python collect-data.py
```

The script will run simulations for various parameter combinations defined within the file.

### Output

The script generates `convergence_times.csv`, which contains the convergence times for each simulation run. This data can be used for performance analysis and generating charts (e.g., using the `convergence_times.xlsx` spreadsheet).

## Algorithm Details

### Gossip

The Gossip algorithm simulates the spread of a "rumor". An actor, upon receiving a rumor for the first time, forwards it to a configurable number of its neighbors. The simulation converges when a certain number of actors have received the rumor.

- **Convergence:** An actor is considered converged if its `rumor_count` reaches `gossip_convergence_threshold` (default: 1000). The simulation ends when the first actor converges.

### Push-Sum

The Push-Sum algorithm is a decentralized method for computing sums. Each actor maintains a `sum` and a `weight`. An actor periodically sends half of its `sum` and `weight` to a random neighbor and keeps the other half.

- **Convergence:** An actor is considered converged when its `s/w` ratio remains stable for a certain number of consecutive steps (default: 3), determined by `push_sum_convergence_threshold` (default: 1.0e-10). The simulation ends when the first actor converges.