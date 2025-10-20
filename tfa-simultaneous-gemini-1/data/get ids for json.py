import json
import sys

def restructure_items(input_file, output_file):
    """
    Restructure JSON items so each item definition is nested within its id property.
    
    Args:
        input_file: Path to input JSON file
        output_file: Path to output JSON file
    """
    # Read the input JSON file
    with open(input_file, 'r') as f:
        items = json.load(f)
    
    # Create new dictionary with id as key
    restructured = {}
    
    for item in items:
        item_id = item.get('id')
        if item_id:
            restructured[item_id] = item
        else:
            print(f"Warning: Item without id found: {item.get('Name', 'Unknown')}")
    
    # Write the restructured data to output file
    with open(output_file, 'w') as f:
        json.dump(restructured, f, indent=2)
    
    print(f"Successfully restructured {len(restructured)} items")
    print(f"Output written to: {output_file}")

if __name__ == "__main__":
    # Check if file paths are provided as command line arguments
    if len(sys.argv) == 3:
        input_file = sys.argv[1]
        output_file = sys.argv[2]
    else:
        # Default file names
        input_file = "Items.json"
        output_file = "Items.json"
    
    try:
        restructure_items(input_file, output_file)
    except FileNotFoundError:
        print(f"Error: File '{input_file}' not found")
    except json.JSONDecodeError:
        print(f"Error: Invalid JSON in '{input_file}'")
    except Exception as e:
        print(f"Error: {e}")