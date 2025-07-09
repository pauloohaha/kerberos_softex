import os
import argparse
import pickle

def analyze_bandwidth(vcd_file):
    
    start_time = 0
    end_time = 0
    up_time = 0
    current_time = 0
    num_val = 0
    prev_req = '0'

    
    tile_start_1dp_16col = 123489120
    tile_end_1dp_16col = 379358470

    tile_start_16dp_5col = 54626340
    tile_end_16dp_5col = 70792964
    tile_gap_16dp_5col = 1970174

    tile_start_16dp_16col = 56377902
    tile_end_16dp_16col = 82708651

    tile_start_16dp_26col = 57985500
    tile_end_16dp_26col = 95442800



    tile_start = tile_start_16dp_5col
    tile_end = tile_end_16dp_5col

    
    with open(vcd_file, 'r') as f:
        
        current_addr = 0
              
        # Skip header until we find $enddefinitions
        for line in f:
            if line.strip() == '$enddefinitions $end':
                break

        # Skip until first non zero value
        for line in f:
            line = line.strip()
            if line.startswith('#0'):
                break

        # Process the actual data
        for line in f:
            line = line.strip()

            # Time
            if line.startswith('#'):
                current_time = int(line[1:].split()[0])

                if start_time == 0:
                    start_time = current_time
                end_time = current_time
            
            # Req
            if line.startswith('b') and line.endswith('!'):
                current_req = line[1:].split()[0][0]
                num_val += 1

                if current_req == '1' and prev_req == '0':
                    up_time -= current_time
                elif current_req == '0' and prev_req == '1':
                    up_time += current_time
                
                prev_req = current_req
            
                # Tile end
                # if current_time == tile_end:
                #     break

        print("up time:", up_time)
        print("down time:", end_time - start_time - up_time)
        print("start time:", start_time)
        print("end time:", end_time)
        print("total time:", end_time - start_time)

        print("mem usage:", up_time/(end_time - start_time))

        print("num values:", num_val)


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