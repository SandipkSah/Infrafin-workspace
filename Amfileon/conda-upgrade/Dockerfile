FROM gpuci/miniconda-cuda:11.4-devel-ubuntu20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/3bf863cc.pub
RUN apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub

RUN apt update && \
    yes | unminimize && \
    apt install -y -o Dpkg::Options::="--force-confold" --force-yes && \
    apt install -y sudo nano acl wget htop bat ncdu cifs-utils vim less tmux make gcc automake xserver-xorg && \
    apt install -y texlive dvipng texlive-latex-extra texlive-fonts-recommended cm-super screen && \
    apt install -y libpq-dev iputils-ping wkhtmltopdf graphviz

RUN conda update -n base -c defaults conda
RUN conda install anaconda
RUN conda install scikit-learn-intelex

RUN apt update && apt install -y mlocate moreutils bat csvkit tldr
RUN git clone https://github.com/jeroenjanssens/dsutils.git /usr/bin/dsutils

# Docker CLI
RUN apt update && apt install -y ca-certificates curl gnupg lsb-release
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN apt update && apt install -y docker-ce-cli

# Do not use the awscli Ubuntu package, it is outdated and missing important features such as 
WORKDIR /root
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN ./aws/install
RUN ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update

RUN apt update && apt install -y -o Dpkg::Options::="--force-confold" --force-yes openssh-server
RUN sed -i "s/#PubkeyAuthentication yes/PubkeyAuthentication yes/" /etc/ssh/sshd_config
RUN sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
RUN echo "HostKey /etc/ssh/keys/ssh_host_rsa_key" >> /etc/ssh/sshd_config
RUN echo "HostKey /etc/ssh/keys/ssh_host_ecdsa_key" >> /etc/ssh/sshd_config
RUN echo "HostKey /etc/ssh/keys/ssh_host_ed25519_key" >> /etc/ssh/sshd_config

# Install newest git client version
RUN apt update && apt install -y software-properties-common nano
RUN add-apt-repository -y ppa:git-core/ppa
RUN apt update && apt install -y git
RUN apt upgrade -y

# Redis
RUN sudo apt update && sudo apt install -y redis-tools groff

# TF
RUN conda install tensorflow

# UV
COPY --from=registry.amf/data/base-image:2025.11.1 /bin/uv /bin/uvx /bin/
 
# NPM
ENV NVM_DIR=/usr/local/.nvm
ENV NODE_VERSION=20.19.3
RUN git clone https://github.com/nvm-sh/nvm.git $NVM_DIR \
    && cd $NVM_DIR \
    && git checkout v0.40.3 \
    && source $NVM_DIR/nvm.sh \
    && nvm install $NODE_VERSION \
    && nvm alias default $NODE_VERSION \
    && nvm use default
ENV PATH=$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH
RUN npm install --global yarn
 
# Other tools
RUN sudo apt update && sudo apt install -y fzf zsh
RUN npm install -g @anthropic-ai/claude-code
RUN /bin/uv venv /opt/tools
RUN /opt/tools/bin/python -m ensurepip --upgrade && /opt/tools/bin/python -m pip install --no-cache-dir pre-commit
ENV PATH="/opt/tools/bin:${PATH}"

# Gitlab CLI
RUN curl -kL https://gitlab.com/gitlab-org/cli/-/releases/v1.65.0/downloads/glab_1.65.0_linux_amd64.deb -o glab.deb \
    && sudo dpkg -i glab.deb
