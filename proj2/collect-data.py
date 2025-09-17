import subprocess
import csv
import re
import statistics

# Parameters
network_sizes = [10, 50, 100]
topologies = ["full", "3d", "line", "imp3d"]
algorithms = ["gossip", "push-sum"]

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

def run_gleam(num_nodes, topology, algorithm):
    cmd = ["gleam", "run", str(num_nodes), topology, algorithm]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return parse_time(result.stderr)
    except Exception as e:
        print(f"Error running {cmd}: {e}")
        return None

# Collect results
rows = []
for n in network_sizes:
    for topo in topologies:
        for algo in algorithms:
            print(f"Running: N={n}, Topology={topo}, Algorithm={algo}")
            times = []
            for _ in range(3):
                conv_time = run_gleam(n, topo, algo)
                if conv_time is not None:
                    times.append(conv_time)
            if len(times) == 3:
                avg_time = statistics.mean(times)
                rows.append([n, topo, algo, times[0], times[1], times[2], avg_time])

# Save to CSV
with open(output_file, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow([
        "numNodes", "topology", "algorithm",
        "run1_ms", "run2_ms", "run3_ms", "average_ms"
    ])
    writer.writerows(rows)

print(f"CSV saved to {output_file}")
