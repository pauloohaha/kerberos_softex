import os
import argparse
import pickle

def analyze_bandwidth(vcd_file, num_tiles=8):

    with open(vcd_file, 'r') as f:
        lines = f.readlines()

    # Find where the data starts
    start_index = 0
    for i, line in enumerate(lines):
        if line.strip() == '$enddefinitions $end':
            start_index = i + 1
            break

    # Skip until first non-zero value (or #0)
    for i, line in enumerate(lines[start_index:]):
        if line.strip().startswith('#0'):
             start_index += i
             break

    lines = lines[start_index:]

    tile_data = []
    current_tile_lines = []
    last_req_time = 0
    in_tile = False
    # Heuristic for gap detection, can be tuned
    # A gap is detected if there is a long period of inactivity
    GAP_THRESHOLD = 1000000 

    current_time = 0
    prev_req = '0'

    for line in lines:
        line = line.strip()
        if not line:
            continue

        if line.startswith('#'):
            current_time = int(line[1:].split()[0])
            if in_tile and prev_req == '0' and (current_time - last_req_time > GAP_THRESHOLD):
                # End of a tile, so we don't append the current '#' line to it
                tile_data.append(current_tile_lines)
                current_tile_lines = []
                in_tile = False

        elif line.startswith('b') and line.endswith('!'):
            current_req = line[1:].split()[0][0]
            if not in_tile and current_req == '1':
                in_tile = True # Start of a new tile
            
            if prev_req != current_req:
                last_req_time = current_time
            prev_req = current_req

            # Update last_req_time on every request to correctly detect gaps
            if in_tile:
                last_req_time = current_time

        if in_tile:
            current_tile_lines.append(line)

    if current_tile_lines:
        tile_data.append(current_tile_lines)

    if len(tile_data) != num_tiles:
        print(f"Warning: Detected {len(tile_data)} tiles, but expected {num_tiles}")

    total_up_time = 0
    total_time = 0

    all_start_times = []
    all_end_times = []
    mem_usages = []

    for i, tile_lines in enumerate(tile_data):
        start_time = 0
        end_time = 0
        up_time = 0
        current_time = 0
        prev_req = '0'

        first_time_set = False
        for line in tile_lines:
            line = line.strip()
            if line.startswith('#'):
                current_time = int(line[1:].split()[0])
                if not first_time_set:
                    start_time = current_time
                    first_time_set = True
                end_time = current_time
            elif line.startswith('b') and line.endswith('!'):
                current_req = line[1:].split()[0][0]
                if current_req != prev_req:
                    relative_time = current_time - start_time
                    if current_req == '1': # 0 -> 1 transition
                        up_time -= relative_time
                    else: # 1 -> 0 transition
                        up_time += relative_time
                    prev_req = current_req

        # If the tile ends with req still high
        if prev_req == '1':
            up_time += (end_time - start_time)

        tile_duration = end_time - start_time
        total_up_time += up_time
        total_time += tile_duration

        all_start_times.append(start_time)
        all_end_times.append(end_time)

        if tile_duration > 0:
            mem_usages.append(up_time / tile_duration)
        else:
            mem_usages.append(0)

    print("--- Summary --- ")
    for i, usage in enumerate(mem_usages):
        print(f"tile{i+1} mem usage: {usage:.2%}")

    if total_time > 0:
        print(f"Overall mem usage (active tiles): {total_up_time/total_time:.2%}")

    if all_start_times and all_end_times:
        total_time_with_gaps = all_end_times[-1] - all_start_times[0]
        if total_time_with_gaps > 0:
            print(f"Overall mem usage (with gaps):  {total_up_time/total_time_with_gaps:.2%}")


if __name__ == '__main__':

    parser = argparse.ArgumentParser(
        description="Analyze the bandwidth of the softex."
    )
    parser.add_argument(
        "vcd_file",
        type=str,
        help="Path to the vcd file"
    )
    args = parser.parse_args()
    analyze_bandwidth(args.vcd_file)