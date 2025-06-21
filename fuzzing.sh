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

# --- Argument Parsing ---
# Usage function
usage() {
    echo "Usage: $0 [-u <url_file>] [-w <wordlist_file>] [-s <tmux_session>]"
    echo "  -u <url_file>       Path to the file containing URLs (one URL per line)."
    echo "  -w <wordlist_file>  Path to the wordlist file."
    echo "  -s <tmux_session>   Name of the current tmux session."
    echo "  -h <web hook>       Web hook url."
    exit 1
}

# Parse command-line arguments
while getopts "u:w:s:h:" opt; do # Added colon for 's' to accept an argument
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
        file_sender.sh -f "$temp_error_file" -n "FFuF_Error_$(date +%Y%m%d%H%M%S)" -m "FFuF Scan Error on $failed_url in session $Session"
        rm -f "$temp_error_file" # Clean up temp file
    else
        echo "Warning: file_sender.sh not found. Could not send error notification." | tee -a "$ERROR_LOG"
    fi

    # Decide whether to exit or continue. For `ffuf` in a loop, you might want to continue.
    # If you want the script to stop entirely on any ffuf error, uncomment the next line:
    # exit 1
}

# Trap the ERR signal. This means if any command fails, the error_handler function is called.
# We're passing $LINENO to the trap function so we know which line caused the error.
trap 'error_handler $LINENO' ERR

# Ensure the script exits if a critical command outside the loop fails, but allow loop errors to be handled by trap.
# We'll control this more granularly within the loop.
set -e

# --- Pre-run Checks ---
# Create the output directory if it doesn't exist
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

echo "Starting FFuF scan..."
echo "URLs will be read from: '$URL_FILE'"
echo "Wordlist being used: '$WORDLIST'"
echo "Results will be saved in: '$OUTPUT_DIR/'"
echo "Errors will be logged to: '$ERROR_LOG'"
echo "--------------------------------------------------"

# Clear previous error log at the start of a new run
> "$ERROR_LOG"

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
    
    # Define the output file for the current URL (HTML format)
    CURRENT_OUTPUT_FILE="${OUTPUT_DIR}/${sanitized_url}.json"
    CURRENT_DEBUG_LOG="${OUTPUT_DIR}/${sanitized_url}_debug.log"

    # Disable 'set -e' for the ffuf command specifically within the loop
    # This allows us to manually check its exit status without triggering the trap for expected `ffuf` failures
    # and ensures the loop continues even if one `ffuf` command fails.
    set +e


    ffuf -u "${url}/FUZZ" -w "$WORDLIST" -o "$CURRENT_OUTPUT_FILE" -of json -ac -debug-log "$CURRENT_DEBUG_LOG"  -sf -v -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36'
    ffuf_exit_status=$?

    # Re-enable 'set -e' for subsequent commands if needed, though for a loop like this,
    # it's often better to rely on explicit checks or the trap for truly unexpected issues.
    # For this script, we'll keep `set -e` off inside the loop and manage `ffuf` errors manually.
    
    if [ $ffuf_exit_status -eq 0 ]; then
        echo "FFuF scan for $url completed successfully. Results saved to $CURRENT_OUTPUT_FILE"
        if command -v file_sender.sh &> /dev/null; then
            file_sender.sh -f "$CURRENT_OUTPUT_FILE" -n "$sanitized_url" -m "Fuzzing Completed on $sanitized_url with session $Session" -h "$hook"
        else
            echo "Warning: file_sender.sh not found. Skipping success notification for $url."
        fi
    else
        echo "FFuF scan for $url encountered an error (Exit Code: $ffuf_exit_status)."
        # Manually trigger error_handler for ffuf specific errors if you want the same logic
        # This will send a notification if file_sender.sh is available and log the error.
        error_handler $LINENO # Manually call the error handler
    fi
    echo "--------------------------------------------------"

done < "$URL_FILE"

# Re-enable set -e after the loop, if desired for post-loop commands
set -e

echo ""
echo "All FFuF scans completed."
exit 0