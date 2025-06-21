#!/bin/bash

# Default values for URL file and wordlist
URL_FILE=""
WORDLIST="" # Example: /usr/share/wordlists/dirb/common.txt
Session=""
hook=""
# Define the output directory for ffuf results
# A subdirectory will be created for each URL's results
OUTPUT_DIR="ffuf_results"
ERROR_LOG="ffuf_error.log" # Dedicated log file for errors

# New variable for temporary split wordlists
SPLIT_WORDLIST_DIR="$OUTPUT_DIR/wordlist_parts_$(date +%s)" # Unique temp dir for each run

# --- Argument Parsing ---
# Usage function
usage() {
    echo "Usage: $0 -u <url_file> -w <wordlist_file> [-s <tmux_session>] [-h <web_hook>]"
    echo "  -u <url_file>       Path to the file containing URLs (one URL per line)."
    echo "  -w <wordlist_file>  Path to the wordlist file."
    echo "  -s <tmux_session>   Name of the current tmux session."
    echo "  -h <web_hook>       Web hook url."
    exit 1
}

# Parse command-line arguments
while getopts "u:w:s:h:" opt; do
    case "$opt" in
        u)
            URL_FILE="$OPTARG"
            ;;
        w)
            WORDLIST="$OPTARG"
            ;;
        s)
            Session="$OPTARG"
            ;;
        h)
            hook="$OPTARG"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# --- Error Handling Function (Catch Block Equivalent) ---
# This function will be executed whenever a command exits with a non-zero status
error_handler() {
    local exit_code=$?
    local line_number=$1
    local current_command="${BASH_COMMAND}"
    local failed_url="${url:-N/A}" # Get the current URL if available, else N/A

    local error_message="ERROR (Line $line_number): Command failed: '$current_command' for URL: $failed_url (Exit Code: $exit_code)"
    echo "$error_message" | tee -a "$ERROR_LOG" # Log to console and error file

    # Attempt to send the error notification
    if command -v file_sender.sh &> /dev/null; then
        # Create a temporary file for the error message to send
        local temp_error_file=$(mktemp)
        echo "$error_message" > "$temp_error_file"
        # Include current URL file, debug log, and error log if they exist
        local files_to_send=("$temp_error_file")
        [ -f "$CURRENT_OUTPUT_FILE" ] && files_to_send+=("$CURRENT_OUTPUT_FILE") # If an output file exists for the failed step
        [ -f "$CURRENT_DEBUG_LOG" ] && files_to_send+=("$CURRENT_DEBUG_LOG")
        [ -f "$ERROR_LOG" ] && files_to_send+=("$ERROR_LOG")

        file_sender.sh -f "${files_to_send[@]}" -n "FFuF_Error_$(date +%Y%m%d%H%M%S)" -m "FFuF Scan Error on $failed_url in session $Session" -h "$hook"
        rm -f "$temp_error_file" # Clean up temp file
    else
        echo "Warning: file_sender.sh not found. Could not send error notification." | tee -a "$ERROR_LOG"
    fi

    # For `ffuf` in a loop, we usually want to continue.
    # If a critical step outside the loop (like splitting) fails, 'set -e' will handle the exit.
}

# Trap the ERR signal. This means if any command fails, the error_handler function is called.
# We're passing $LINENO to the trap function so we know which line caused the error.
trap 'error_handler $LINENO' ERR

# Ensure the script exits if a critical command outside the loop fails,
# but allow loop errors to be handled by the trap (set +e for ffuf specifically).
set -e

# --- Pre-run Checks ---
# Create the main output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Check if the URL file exists
if [ ! -f "$URL_FILE" ]; then
    echo "Error: URL file '$URL_FILE' not found."
    usage
fi
dos2unix "$URL_FILE"

# Check if the wordlist exists
if [ ! -f "$WORDLIST" ]; then
    echo "Error: Wordlist '$WORDLIST' not found."
    usage
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' command not found. Please install jq to combine JSON results."
    echo "  On Debian/Ubuntu: sudo apt-get install jq"
    echo "  On CentOS/RHEL/Fedora: sudo yum install jq"
    exit 1
fi

echo "Starting FFuF scan and wordlist splitting..."
echo "URLs will be read from: '$URL_FILE'"
echo "Wordlist being used: '$WORDLIST'"
echo "Results will be saved in: '$OUTPUT_DIR/'"
echo "Errors will be logged to: '$ERROR_LOG'"
echo "--------------------------------------------------"

# Clear previous error log at the start of a new run
> "$ERROR_LOG"

# --- Step 1: Split the wordlist once at the beginning ---
mkdir -p "$SPLIT_WORDLIST_DIR" || {
    echo "Error: Could not create temporary directory '$SPLIT_WORDLIST_DIR'. Exiting." | tee -a "$ERROR_LOG"
    exit 1
}
echo "Splitting wordlist '$WORDLIST' into 4 parts..."
split -n l/4 --numeric-suffixes=1 --suffix-length=2 "$WORDLIST" "$SPLIT_WORDLIST_DIR/part_" --additional-suffix=".txt" || {
    echo "Error: Failed to split wordlist '$WORDLIST'. Exiting." | tee -a "$ERROR_LOG"
    exit 1
}
echo "Wordlist split successfully. Parts are in $SPLIT_WORDLIST_DIR."
echo "--------------------------------------------------"


# --- Main FFuF Loop ---
# Read each URL from the file
while IFS= read -r url; do
    # Skip empty lines
    if [ -z "$url" ]; then
        continue
    fi

    echo ""
    echo "Scanning: $url"
    echo "--------------------------------------------------"
    
    # Sanitize the URL to create a valid filename for output
    sanitized_url=$(echo "$url" | sed -e 's/[^a-zA-Z0-9._-]/_/g' -e 's/^-//' -e 's/-$//')
    
    # Define the final combined output file for this URL
    FINAL_COMBINED_OUTPUT_FILE="${OUTPUT_DIR}/${sanitized_url}_combined.json"
    
    # Array to hold paths of successful temporary JSON part files for this URL
    declare -a json_part_files_for_url

    # --- Step 2: Inner loop for each split wordlist part ---
    for split_wordlist_file in "$SPLIT_WORDLIST_DIR"/part_*.txt; do
        if [ ! -f "$split_wordlist_file" ]; then
            echo "Warning: Split wordlist part '$split_wordlist_file' not found. Skipping." | tee -a "$ERROR_LOG"
            continue
        fi

        local part_name=$(basename "$split_wordlist_file" .txt) # e.g., part_01
        local part_output_file="${OUTPUT_DIR}/${sanitized_url}_${part_name}.json"
        local part_debug_log="${OUTPUT_DIR}/${sanitized_url}_${part_name}_debug.log"

        echo "  - Using wordlist part: $split_wordlist_file"
        echo "  - Outputting temporary results to: $part_output_file"

        # Disable 'set -e' specifically for the ffuf command within the loop
        set +e
        ffuf -u "${url}/FUZZ" -w "$split_wordlist_file" -o "$part_output_file" -of json -ac -debug-log "$part_debug_log" -sf -v -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36'
        ffuf_exit_status=$?
        set -e # Re-enable set -e after ffuf

        if [ $ffuf_exit_status -eq 0 ]; then
            echo "  FFuF scan for $url with $part_name completed successfully."
            json_part_files_for_url+=("$part_output_file") # Add to array for merging
        else
            echo "  FFuF scan for $url with $part_name encountered an error (Exit Code: $ffuf_exit_status)."
            error_handler $LINENO # Manually call the error handler for this ffuf specific error
        fi
    done # End of split wordlist loop for the current URL

    echo "--------------------------------------------------"
    echo "Combining results for $url..."

    # --- Step 3: Combine JSON outputs using jq ---
    if [ ${#json_part_files_for_url[@]} -gt 0 ]; then
        # Use jq to read each JSON file, extract its .results array, and combine them.
        # Then wrap the combined array in a new JSON object with a "results" key.
        
        # Create a temporary file to hold the combined results array
        local temp_combined_array_file="${FINAL_COMBINED_OUTPUT_FILE}.tmp_array"

        # Extract all 'results' arrays and concatenate them into a single JSON array
        # This uses 'map(.results[])' to flatten all 'results' arrays from input files into one
        jq -s 'map(.results[])' "${json_part_files_for_url[@]}" > "$temp_combined_array_file" || {
            echo "Error: Failed to combine JSON arrays for $url using jq." | tee -a "$ERROR_LOG"
            error_handler $LINENO # Call error handler for combination failure
            rm -f "$temp_combined_array_file" # Clean up temp
            continue # Move to next URL
        }

        # Wrap the combined array into the final FFuF JSON structure
        jq -n --argfile combined_results "$temp_combined_array_file" '{ "results": $combined_results }' > "$FINAL_COMBINED_OUTPUT_FILE" || {
            echo "Error: Failed to wrap combined JSON array for $url using jq." | tee -a "$ERROR_LOG"
            error_handler $LINENO # Call error handler for wrapping failure
            rm -f "$temp_combined_array_file" # Clean up temp
            continue # Move to next URL
        }
        
        rm -f "$temp_combined_array_file" # Clean up temporary combined array file
        
        if [ $? -eq 0 ]; then
            echo "Combined results saved to ${FINAL_COMBINED_OUTPUT_FILE}"
            # Send combined file notification
            if command -v file_sender.sh &> /dev/null; then
                file_sender.sh -f "$FINAL_COMBINED_OUTPUT_FILE" -n "${sanitized_url}_combined_ffuf_results" -m "Fuzzing Results for $sanitized_url in session $Session" -h "$hook"
            else
                echo "Warning: file_sender.sh not found. Skipping combined results notification for $url."
            fi
        fi
    else
        echo "No successful FFuF results found for $url to combine (all parts failed or no output)."
    fi

    # Clean up individual part JSON files and debug logs for this URL to save space
    echo "Cleaning up temporary individual JSON part files and logs for $url..."
    rm -f "${OUTPUT_DIR}/${sanitized_url}_part_*.json"
    rm -f "${OUTPUT_DIR}/${sanitized_url}_part_*.log"

done < "$URL_FILE"

# --- Final Cleanup: Remove the temporary split wordlist directory ---
echo "All FFuF scans completed. Cleaning up temporary split wordlist directory: $SPLIT_WORDLIST_DIR"
rm -rf "$SPLIT_WORDLIST_DIR"

# Re-enable set -e after the loop, if desired for post-loop commands (it should already be enabled if no `set +e` after the loop)
set -e

echo ""
echo "Script execution finished."
exit 0
