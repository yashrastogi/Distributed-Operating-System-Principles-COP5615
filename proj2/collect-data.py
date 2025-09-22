import os
import subprocess
import csv
import re
import statistics

# Parameters
# network_sizes = [8, 27, 64, 125, 216, 343, 512, 729, 1000]
network_sizes = [i * i * i for i in range(2, 7)]
topologies = ["line", "3d", "imp3d", "full"]
algorithms = ["gossip", "push-sum"]
kill_percents = [0]

# Output CSV file
output_file = "convergence_times.csv"


def parse_time(output: str):
    """
    Parse lines like:
    [#(20, Second), #(691, MilliSecond), #(125, MicroSecond)]
    and return total time in milliseconds (float).
    """
    seconds = milliseconds = microseconds = 0
    matches = re.findall(r"#\((\d+), (\w+)\)", output)
    for val, unit in matches:
        val = int(val)
        if unit.lower().startswith("second"):
            seconds = val
        elif unit.lower().startswith("milli"):
            milliseconds = val
        elif unit.lower().startswith("micro"):
            microseconds = val

    total_ms = seconds * 1000 + milliseconds + microseconds / 1000
    return total_ms


def parse_convergence_value(output: str, algorithm: str):
    """
    Extract the convergence value from lines like:
    Actor 865 converged with s/w ratio: 500.50000000001586
    If algorithm is gossip, return 'N/A'.
    """
    if algorithm == "push-sum":
        match = re.search(r"ratio:\s*([\d\.Ee+-]+)", output)
        if match:
            return match.group(1)
    return "N/A"


def run_gleam(num_nodes, topology, algorithm, kill_percent):
    cmd = ["gleam", "run", str(num_nodes), topology, algorithm, str(kill_percent)]
    try:
        result = subprocess.run(
            cmd,
            text=True,
            check=True,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        conv_time = parse_time(result.stderr)
        conv_value = parse_convergence_value(result.stdout, algorithm)
        return conv_time, conv_value
    except Exception as e:
        print(f"Error running {cmd}: {e}")
        return None, None


# Collect results
rows = []
for algo in algorithms:
    for n in network_sizes:
        for topo in topologies:
            for k in kill_percents:
                print(
                    f"Running: N={n}, Topology={topo}, Algorithm={algo}, KillPercent={k}:"
                )
                times = []
                for x in range(3):
                    conv_time, conv_value = run_gleam(n, topo, algo, k)
                    print(f"Run {x + 1}: {conv_time}ms")
                    if conv_time is not None:
                        times.append((conv_time, conv_value))
                if len(times) == 3:
                    avg_time = statistics.mean([t[0] for t in times])
                    rows.append(
                        [
                            n,
                            topo,
                            algo,
                            times[0][0],
                            times[1][0],
                            times[2][0],
                            avg_time,
                            times[0][1],
                            times[1][1],
                            times[2][1],
                            k,
                        ]
                    )

header = [
    "numNodes",
    "topology",
    "algorithm",
    "run1_ms",
    "run2_ms",
    "run3_ms",
    "average_ms",
    "convergence_value_1",
    "convergence_value_2",
    "convergence_value_3",
    "kill_percent",
]

file_exists = os.path.exists(output_file)
with open(output_file, "a" if file_exists else "w", newline="") as f:
    writer = csv.writer(f)
    # Write header only if file does not exist
    if not file_exists:
        writer.writerow(header)
    writer.writerows(rows)

print(f"CSV {'appended to' if file_exists else 'saved to'} {output_file}")
