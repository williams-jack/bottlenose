FROM orca-grader-base:latest

RUN apt-get update && apt-get install -y software-properties-common tree xvfb libcairo2 libpango1.0-0 libgtk2.0-0
RUN curl -L -o racket-8.14.sh https://download.racket-lang.org/installers/8.14/racket-8.14-x86_64-linux-cs.sh && \
    sh racket-8.14.sh --unix-style --dest /usr/ --create-dir && rm racket-8.14.sh

USER orca-grader
