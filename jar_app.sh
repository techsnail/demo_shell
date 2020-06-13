#!/bin/bash
export LANG=en_US.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 应用启动用户
user=exampleuser
# 应用启动超时时间(未提供健康检查uri时)
start_timeout=10
# 应用启动超时时间(有提供健康检查uri时)
start_timeout_with_health=120
# 应用关闭超时时间
shutdown_timeout=20
# 应用健康检查uri
health_uri=/health

# Source function library.
. /etc/rc.d/init.d/functions

# 获取本脚本所在目录
basepath=$(cd `dirname $0`; pwd)
# 获取父目录(应用安装目录)
parent_path=`dirname ${basepath}`
cd ${parent_path}

# 先尝试获取runtime目录下的jar包名称，如没有，再获取package目录下的jar包名称
function get_jar_name() {
	i=0
	for subdir in runtime package rollback
	do
		number=`ls ${subdir}/*.jar 2> /dev/null | wc -l`
		if [ ${number} -eq 0 ]; then
			jar_name[$i]='no_exist'
		elif [ ${number} -eq 1 ]; then
			jar_name[$i]=$(basename `ls ${subdir}/*.jar`)
		else
			jar_name[$i]='too_many'
		fi
		let "i=i+1"
	done
	runtime_jar_name=${jar_name[0]}
	package_jar_name=${jar_name[1]}
	rollback_jar_name=${jar_name[2]}
}

# 检查jar包运行状态：运行，返回值为0；未运行，返回值为1。
# 本函数需提供给其它函数调用。本函数中不对runtime目录下的jar包数量做校验，交给调用它的函数进行校验。
function status_jar() {
	get_jar_name
	pids=`ps -f -C java --no-headers | grep -E "(/|\s)+${runtime_jar_name}" | awk '{print $2}'`
	# 为了解决新旧项目切换的问题，增加如下代码
	###################################
	if [ -z "${pids}" ]; then
		pids=`ps -f -C java --no-headers | grep -E "(/|\s)+${package_jar_name}" | awk '{print $2}'`
	fi
	###################################
	if [ -n "${pids}" ]; then
		return 0
	else
		return 1
	fi
}

# 本函数检查runtime目录下面jar包的数量。
# 本函数需提供给其它函数调用。
function check_runtime_jar() {
	get_jar_name
	if [ "${runtime_jar_name}" == "no_exist" ]; then
		echo "[INFO] No jar package is found under '${parent_path}/runtime' directory."
		exit 1
	fi
	if [ "${runtime_jar_name}" == "too_many" ]; then
		echo "[INFO] Two or more jar packages are found under '${parent_path}/runtime' directory."
		exit 1
	fi
}

# 本函数实现本脚本的status功能。
# 本函数不提供给其它函数调用。
function status_function() {
	check_runtime_jar
	status_jar
	if [ $? -eq 0 ]; then
		echo "[INFO] Jar package '${runtime_jar_name}' is running."
	else
		echo "[INFO] Jar package '${runtime_jar_name}' is not running."
	fi
}

# 停止jar包。
# 本函数需提供给其它函数调用。本函数中不对runtime目录下的jar包数量做校验，交给调用它的函数进行校验。
function stop_jar() {
	status_jar
	if [ $? -eq 1 ]; then
		echo "[INFO] The program is not running. No need to stop it."
		return 0
	fi
	echo "[INFO] Shutting down program . . . . . . "
	for pid in ${pids}; do
		kill ${pid}
	done
	timeout=${shutdown_timeout}
	step=2
	for (( count=0; count<timeout; count=count+step))
	do
		sleep $step
		status_jar
		if [ $? -eq 1 ]; then
			echo "[INFO] Shutting down program successfully."
			return 0
		fi
	done

	for pid in ${pids}; do
		kill -9 ${pid}
	done
	sleep 11
	python ./bin/delete_critical_services.py
	echo "[WARNING] Program has been killed forcibly."
}

# 本函数实现本脚本的stop功能。
# 本函数不提供给其它函数调用。
function stop_function() {
	check_runtime_jar
	stop_jar
}

# 运行jar包。
# 本函数需提供给其它函数调用。本函数中不对runtime目录下的jar包数量做校验，交给调用它的函数进行校验。
function start_jar() {
	status_jar
	if [ $? -eq 0 ]; then
		echo "[INFO] The program is running. No need to start it again."
		return 0
	fi
	echo "[INFO] Starting program . . . . . . "
	# 启动程序前确保先切换到应用根目录，因有些jar程序会将它的日志写到相对启动路径的logs/目录中。
	cd ${parent_path}
	if [ $UID -eq 0 ]; then
		daemon --user=${user} java -server -Xmx2048m -Xms2048m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp -Xloggc:/tmp/gc_`date +%Y%m%d%H%M%S`.log -jar ${parent_path}/runtime/${runtime_jar_name} >/dev/null 2>&1 &
	else
		daemon java -server -Xmx2048m -Xms2048m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp -Xloggc:/tmp/gc_`date +%Y%m%d%H%M%S`.log -jar ${parent_path}/runtime/${runtime_jar_name} >/dev/null 2>&1 &
	fi

	if [ "${health_uri}" == "null" ]; then
		sleep ${start_timeout}
		status_jar
		if [ $? -eq 0 ]; then
			echo "[INFO] Starting program successfully."
			return 0
		fi
	else
		timeout=${start_timeout_with_health}
		step=10
		for (( count=0; count<timeout; count=count+step))
		do
			sleep $step
			status_jar
			if [ $? -ne 0 ]; then
				echo "[ERROR] Starting program fails."
				exit 1
			else
				pid=${pids}
				port=`netstat -tlpn 2>/dev/null | awk '$0 ~ /\<'${pid}'\//{print $4}' | awk -F ':' '{print $NF}'`
				if [ -z "${port}" ]; then
					continue
				else
					health_url="http://127.0.0.1:${port}${health_uri}"
					http_status="`curl -I -s -o /dev/null -w %{http_code} --connect-timeout 1 --max-time 1 ${health_url}`"
					if [ -n "`echo -n ${http_status} | grep 200`" ]; then
						echo "[INFO] Starting program successfully."
						return 0
					fi
				fi
			fi
		done
	fi

	echo "[ERROR] Starting program times out."
	exit 1
}

# 本函数实现本脚本的start功能。
# 本函数不提供给其它函数调用。
function start_function() {
	check_runtime_jar
	start_jar
}

# 本函数实现本脚本的restart功能。
# 本函数不提供给其它函数调用。
function restart_function() {
	check_runtime_jar
	stop_jar
	start_jar
}

# 本函数实现本脚本的backup功能。
# 本函数不提供给其它函数调用。
function backup_function() {
	check_runtime_jar
	cp  -a  runtime/${runtime_jar_name}  backup/${runtime_jar_name}.bak_`date +%Y%m%d_%H:%M:%S`
	echo "[INFO] Package '${parent_path}/runtime/${runtime_jar_name}' has been backed up successfully."
}

# 本函数实现本脚本的update功能。
# 本函数不提供给其它函数调用。
function update_function() {
	get_jar_name
	if [ "${package_jar_name}" == "no_exist" ]; then
		echo "[INFO] No jar package is found under '${parent_path}/package' directory."
		exit 1
	fi
	if [ "${package_jar_name}" == "too_many" ]; then
		echo "[INFO] Two or more jar packages are found under '${parent_path}/package' directory."
		exit 1
	fi
	if [ "${runtime_jar_name}" == "too_many" ]; then
		echo "[INFO] Two or more jar packages are found under '${parent_path}/runtime' directory."
		exit 1
	fi
	echo "[INFO] Starting to update . . . "
	if [ "${runtime_jar_name}" == "no_exist" ]; then
		echo "[INFO] No jar package is found under '${parent_path}/runtime' directory."
		# 为了解决新旧项目切换的问题，增加如下代码
		###################################
		stop_jar
		###################################
	else
		cp  -a  runtime/${runtime_jar_name}  backup/${runtime_jar_name}.bak_`date +%Y%m%d_%H:%M:%S`
		rm -f rollback/*.jar
		cp -a runtime/${runtime_jar_name} rollback/${runtime_jar_name}
		stop_jar
		rm -f runtime/*.jar
	fi
	mv -f package/${package_jar_name} runtime/${package_jar_name}
	get_jar_name
	start_jar
	echo "[INFO] Program has been updated successfully."
}

# 本函数实现本脚本的rollback功能。
# 本函数不提供给其它函数调用。
function rollback_function() {
	get_jar_name
	if [ "${rollback_jar_name}" == "no_exist" ]; then
		echo "[INFO] No jar package is found under '${parent_path}/rollback' directory."
		exit 1
	fi
	if [ "${rollback_jar_name}" == "too_many" ]; then
		echo "[INFO] Two or more jar packages are found under '${parent_path}/rollback' directory."
		exit 1
	fi
	if [ "${runtime_jar_name}" == "too_many" ]; then
		echo "[INFO] Two or more jar packages are found under '${parent_path}/runtime' directory."
		exit 1
	fi
	echo "[INFO] Starting to roll back . . . "
	if [ "${runtime_jar_name}" == "no_exist" ]; then
		echo "[INFO] No jar package is found under '${parent_path}/runtime' directory. No need to stop it."
	else
		stop_jar
		rm -f runtime/*.jar
	fi
	mv -f rollback/${rollback_jar_name} runtime/${rollback_jar_name}
	get_jar_name
	start_jar
	echo "[INFO] Program has been rolled back successfully."
}

case "$1" in
	'start')
		start_function
	;;
	'stop')
		stop_function
	;;
	'restart')
		restart_function
	;;
	'status')
		status_function
	;;
	'backup')
		backup_function
	;;
	'update')
		update_function
	;;
	'rollback')
		rollback_function
	;;
	*)
		echo "Usage: $0 {start|stop|restart|status|backup|update|rollback}"
esac
