FROM orca-grader-base:latest

RUN apt-get update
RUN apt install software-properties-common
RUN apt-get install -y tree xvfb libcairo2 libpango1.0-0 libgtk2.0-0
RUN apt-get clean
RUN curl -L -o racket-8.14-x86_64-linux-cs.sh \
  https://download.racket-lang.org/installers/8.14/racket-8.14-x86_64-linux-cs.sh
RUN sh racket-8.14-x86_64-linux-cs.sh --unix-style
RUN rm racket-8.14-x86_64-linux-cs.sh

USER orca-grader
