#!/usr/bin/env bash
set -o nounset
set -o errexit
set -E
set -x

make_target_devenv() {
	readonly target="$1"

	# example: target/debs/bullseye/swss_1.0.0_amd64.deb -> swss
	readonly service="$(echo $target | egrep -o "[^/]+\.deb$" | egrep -o "[a-zA-Z]+" | head -n 1)"

	readonly sonic_opts="NOSTRETCH=1 NOBUSTER=1 BLDENV=bullseye"
	readonly tag="$RANDOM"
	readonly sonic_image_open_latch_file="sonic_image_open_latch_file-${tag}"
	trap "rm $sonic_image_open_latch_file" EXIT

	readonly sonic_image_stored_latch_file="sonic_image_stored_latch_file-${tag}"
	trap "rm $sonic_image_stored_latch_file" EXIT

	readonly tmp_command_file="$(mktemp)"
	trap "rm $tmp_command_file" EXIT
	cat <<- EOF > "$tmp_command_file"
	touch $sonic_image_open_latch_file
	until [ -f "$sonic_image_stored_latch_file" ]; do sleep 1 && echo waiting to close... ; done
	exit
	EOF

	# workaround: make sure no containers are running
	(
		readonly running_containers="$(docker ps --format json)"
		test "$running_containers" && (echo stop all docker containers for this script to work, please... && exit 1) || true
	)

	echo --- start sonic builder slave container
	readonly build_log="log-build-${tag}.txt"
	rm "$target" || true
	( make $sonic_opts KEEP_SLAVE_ON=yes "$target" < "$tmp_command_file" > "$build_log" 2>&1 ) &
	trap "touch $sonic_image_stored_latch_file" EXIT

	until [ -f "$sonic_image_open_latch_file" ]; do sleep 5s && echo waiting for $service container to be ready... ; done

	echo --- make sure the sonic build went without errors
	egrep "exit [1-9]" "$build_log" && echo "found errors in sonic build, check $build_log for details" && exit 1 || true

	echo --- store the sonic builder slave container
	readonly container_name="$(docker ps -n 1 --format "{{ .Names }}")"
	test "$container_name" || (echo could not get the running sonic builder container name && exit 1)
	readonly raw_devenv_image="sonic-slave-bullseye-${USER}:${service}-raw"
	docker commit "$container_name" "$raw_devenv_image"
	touch "$sonic_image_stored_latch_file"

	echo --- create dockerfile
	readonly dockerfile_name="Dockerfile.${service}.${tag}"
	trap "rm $dockerfile_name" EXIT
	cat <<- EOF > "$dockerfile_name"

	FROM $raw_devenv_image

	USER root

	RUN apt update && \
		apt install -y \
			openssh-server \
			ccache
	RUN echo '${USER}:${USER}' | chpasswd

	WORKDIR /workdir
	RUN service ssh start
	EXPOSE 22
	ENTRYPOINT ["/usr/sbin/sshd","-D"]

	EOF

	echo --- build devenv image
	readonly devenv_image_base="sonic-slave-bullseye-${USER}:${service}-devenv"
	readonly devenv_image="${devenv_image_base}-${tag}"
	docker build -f "$dockerfile_name" -t "$devenv_image" .
	docker tag "$devenv_image" "$devenv_image_base"
	echo created devenv image $devenv_image for target $target
}

"$@"