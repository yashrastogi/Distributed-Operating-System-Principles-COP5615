import os
import subprocess
import csv
import re
import statistics

# Parameters
network_sizes = [8, 27, 64, 125, 216, 343, 512, 729, 1000]
topologies = ["3d", "imp3d"]
algorithms = ["gossip", "push-sum"]

# Output CSV file
output_file = "convergence_times_line.csv"

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

def run_gleam(num_nodes, topology, algorithm):
    cmd = ["gleam", "run", str(num_nodes), topology, algorithm]
    try:
        result = subprocess.run(cmd, text=True, check=True, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
        return parse_time(result.stderr)
    except Exception as e:
        print(f"Error running {cmd}: {e}")
        return None

# Collect results
rows = []
for algo in algorithms:
    for n in network_sizes:
        for topo in topologies:
            print(f"Running: N={n}, Topology={topo}, Algorithm={algo}:")
            times = []
            for x in range(3):
                conv_time = run_gleam(n, topo, algo)
                print(f'Run {x + 1}: {conv_time}ms')
                if conv_time is not None:
                    times.append(conv_time)
            if len(times) == 3:
                avg_time = statistics.mean(times)
                rows.append([n, topo, algo, times[0], times[1], times[2], avg_time])

header = [
    "numNodes", "topology", "algorithm",
    "run1_ms", "run2_ms", "run3_ms", "average_ms"
]

file_exists = os.path.exists(output_file)
with open(output_file, "a" if file_exists else "w", newline="") as f:
    writer = csv.writer(f)
    # Write header only if file does not exist
    if not file_exists:
        writer.writerow(header)
    writer.writerows(rows)

print(f"CSV {'appended to' if file_exists else 'saved to'} {output_file}")
