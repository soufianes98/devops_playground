#!/usr/bin/env bash

# Entry point
main() {
    case $1 in
    "setup")
        source .github/scripts/setup.sh
        ;;
    "publish")
        source .github/scripts/publish.sh
        ;;
    *)
        echo "default: INVALID OPTION"
        ;;
    esac
}

# Here we check that the number of arguments is greater than 0
if [[ $# -ge 1 ]]; then
    # Invoking main function
    main "$@"
    exit 0
else
    echo "Please provide the required arguments!"
    exit 1
fi

