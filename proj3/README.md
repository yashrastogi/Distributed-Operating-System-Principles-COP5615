# Chord DHT: OTP-style Actor Implementation (Gleam)

## Team Members:
- Yash Rastogi  
- Pavan Karthik Chilla


## Overview

This project implements a **Chord Distributed Hash Table (DHT)** using OTP-style actors in [Gleam](https://gleam.run/). Each Chord node is encapsulated as an actor, with protocol logic for joining/leaving, finger table management, and stabilization routines. The implementation supports large peer-to-peer network simulations, demonstrating scalable distributed operation.

**Status:**  
- **Working:** All core functionalities (node join/leave, stabilization, routing, data put/get, finger table maintenance)  
- **Max Network Tested:** 500 nodes


## Features

- **Chord DHT Protocol:** Implements node addition/removal, SHA1-based identifiers, routing, key storage, and retrieval.
- **Actor-based Concurrency:** Each node acts as an OTP-style actor, allowing message-based asynchronous logic.
- **Finger Table Management:** Periodic updating to maintain efficient routing ($\mathcal{O}(\log N)$ hops).
- **Network Stabilization:** Background actors periodically stabilize successors/predecessors and fix fingers.
- **Data Put/Get:** Key-value insertion and retrieval with storage at the responsible node.
- **Extensive Logging:** **Prints average number of hops that have to be traversed to deliver a message** and hops data, successor/predecessor, and routing information for analysis.


## File Structure

- **proj3.gleam**: Main source code
- **sentences.txt**: Sample dataset for PUT/GET operations


## Usage

### Prerequisites

- Gleam language (and OTP backend with Erlang runtime)

### Build & Run

```bash
gleam run project3 <num_nodes> <num_requests>
```

- **num_nodes**: Number of nodes to spawn in the Chord ring
- **num_requests**: Number of lookup requests each node will issue

### Example

```bash
gleam run project3 100 5
```

This command initializes 100 Chord nodes, each performing 5 GET operations.


## Major Code Sections

- **main:** Entry point; parses arguments, starts actors, bootstraps network, launches background stabilization/finger-fixing actors, and manages test PUT/GET cycles.
- **create_actors:** Initializes all node actors, builds routing table, triggers joining via initial node.
- **chord_node_handler:** Core actor message handler implementing Chord protocol logic (join, stabilization, PUT/GET, routing table/finger table operations).
- **Routing & Stabilization:** Functions for node discovery, finger table updates, successor/predecessor stabilization, and data transfer between nodes.
- **Helpers:** Unique node/data hashing, ring arithmetic, command-line parsing, liveness checking, background periodic routines.


## Algorithm Details

- **Node ID Generation:** Node indices are hashed using SHA1 (hex string, length 160).
- **Finger Tables:** Each node maintains up to 160 finger entries for $\mathcal{O}(\log N)$ lookup.
- **Ring Arithmetic:** Custom logic for wrap-around comparisons and interval inclusion.
- **Data Distribution:** Key-value pairs are SHA1-hashed; stored at the node whose ID succeeds the key in the ring.
- **Stabilization:** Actors periodically fix finger entries and verify/notify successors/predecessors.
- **Network Bootstrap:** All nodes join via the first node acting as the initial point of contact.


## Largest Network Simulated

- Up to **500 nodes** in a single run, scales well with actor concurrency and efficient finger table routing.


## Authors

- **Yash Rastogi**
- **Pavan Karthik Chilla**


## References

- [Chord: A Scalable Peer-to-peer Lookup Protocol](https://pdos.csail.mit.edu/papers/chord:sigcomm01/chord_sigcomm.pdf)
- Gleam Language Documentation