ARG RUBY_VERSION=3.1.2
FROM ruby:${RUBY_VERSION} as base

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -o Acquire::Max-FutureTime=86400 update \
 && apt-get install --no-install-recommends -y \
      apt-utils \
      build-essential \
      clang \
      git \
      less \
      libssl-dev \
      lldb \
      lsb-release \
      netcat \
      procps \
      xz-utils \
 && gem install bundler rcodetools rubocop ruby-debug-ide fastri

# Switch back to dialog for any ad-hoc use of apt-get
ENV DEBIAN_FRONTEND=dialog

COPY Gemfile* semian.gemspec /workspace/
COPY lib /workspace/lib

WORKDIR /workspace
RUN bundle install
