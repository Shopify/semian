FROM ruby:2.7.1

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get -y install --no-install-recommends apt-utils 2>&1 \
    && apt-get install -y build-essential libssl-dev git procps lsb-release less \
    xz-utils clang lldb

RUN gem install bundler:2.0.2 rcodetools rubocop ruby-debug-ide fastri

# Switch back to dialog for any ad-hoc use of apt-get
ENV DEBIAN_FRONTEND=dialog
