import pandas as pd
import json

def parse_json_string(value):
    """
    Attempts to parse a string as a JSON object.
    If parsing fails, returns the original value.
    """
    if isinstance(value, str):
        try:
            # Note: json.loads requires double quotes for strings
            # e.g., '{"key": "value"}' is valid, but "{'key': 'value'}" is not.
            return json.loads(value)
        except (json.JSONDecodeError, TypeError):
            # Not a valid JSON string, return the original string
            return value
    return value

def convert_excel_to_json(excel_path, json_path):
    """
    Reads an Excel file, processes its cells for JSON objects,
    and saves the data as a JSON file.
    """
    try:
        # 1. Read the Excel file into a pandas DataFrame
        df = pd.read_excel(excel_path)

        # 2. Apply the parsing function to every cell in the DataFrame
        # The .applymap() method efficiently applies our function to each element.
        parsed_df = df.applymap(parse_json_string)

        # 3. Convert the processed DataFrame to a JSON string
        # 'records' orientation creates a list of objects, one for each row.
        # indent=4 makes the JSON output human-readable.
        json_output = parsed_df.to_json(orient='records', indent=4)

        # 4. Save the JSON string to a file
        with open(json_path, 'w') as f:
            f.write(json_output)

        print(f"✅ Successfully converted '{excel_path}' to '{json_path}'")

    except FileNotFoundError:
        print(f"❌ Error: The file '{excel_path}' was not found.")
    except Exception as e:
        print(f"❌ An unexpected error occurred: {e}")

# --- Main execution block ---
if __name__ == "__main__":
    # Define the input and output file paths
    excel_file_path = 'Items.xlsx'
    json_file_path = 'Items.json'

    # Run the conversion
    convert_excel_to_json(excel_file_path, json_file_path)