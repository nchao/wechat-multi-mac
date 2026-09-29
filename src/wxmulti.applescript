-- 微信多开 (self-contained)
-- 复制 WeChat.app 为独立副本，改 CFBundleIdentifier 后 adhoc 重签名，实现账号数据隔离。
-- 不需要管理员密码：/Applications 对 admin 组可写，微信 app 归当前用户。

property baseApp : "/Applications/WeChat.app"
property baseId : "com.tencent.xinWeChat"
property binRel : "Contents/MacOS/WeChat"

-- 列表末尾的两个特殊项。choose from list 只有确定/取消两个按钮，
-- 加不了自定义按钮，所以把「＋／－」做成列表条目。
property baseLabel : "WeChat（原版）"
property addLabel : "＋  新建副本"
property delLabel : "－  卸载副本"

on run
	if not (my pathExists(baseApp)) then
		display alert "找不到微信" message "预期位置 " & baseApp & "，请先安装微信。" as critical
		return
	end if
	if not (my appsWritable()) then
		display alert "没有写入权限" message "当前账户对 /Applications 没有写权限，需要管理员账户。" as critical
		return
	end if

	-- 增删完回到列表继续，启动或取消才退出
	repeat
		set copies to my listCopies()
		set opts to {baseLabel} & copies & {addLabel, delLabel}
		set picked to my chooseMany("微信多开", "选择要启动的微信（可多选），或用下方 ＋／－ 增删副本：", opts)
		if (count of picked) is 0 then return

		set special to ""
		repeat with p in picked
			set v to p as text
			if v is addLabel or v is delLabel then
				set special to v
				exit repeat
			end if
		end repeat

		if special is addLabel then
			my doCreate()
		else if special is delLabel then
			if (count of copies) is 0 then
				display alert "没有副本可卸载" message "先用「＋ 新建副本」做一个。原版微信不能卸载。" as informational
			else
				my doUninstall(copies)
			end if
		else
			my launchPicked(picked)
			return
		end if
	end repeat
end run

-- ========== 三个操作 ==========

-- 原版直接激活窗口，副本走完整的改 id + 签名 + 启动流程
on launchPicked(picked)
	set names to {}
	set wantBase to false
	repeat with p in picked
		set v to p as text
		if v is baseLabel then
			set wantBase to true
		else
			set end of names to v
		end if
	end repeat
	if wantBase then my activateApp(baseApp)
	if (count of names) > 0 then my processAll(names, false)
end launchPicked

on doCreate()
	try
		set input to text returned of (display dialog "新副本的名字，多个用空格隔开（不要带 .app）：" default answer my nextFreeName() with title "微信多开 - 新建")
	on error
		return
	end try
	set names to my splitWords(input)
	if (count of names) is 0 then return
	my processAll(names, true)
end doCreate

on doUninstall(copies)
	-- copies 由调用方传入，已排除原版微信
	set picked to my chooseMany("卸载副本", "选择要卸载的副本（可多选）：", copies)
	if (count of picked) is 0 then return

	set listText to my joinList(picked, ", ")
	try
		set btn to button returned of (display dialog "将卸载：" & listText & return & return & "app 会移入废纸篓。聊天数据（~/Library/Containers）怎么处理？" with title "微信多开 - 卸载确认" buttons {"取消", "一起删除", "保留数据"} default button "保留数据")
	on error
		return
	end try
	if btn is "取消" then return
	set purge to (btn is "一起删除")

	set total to count of picked
	set progress total steps to total
	set progress description to "正在卸载…"
	set report to ""
	repeat with i from 1 to total
		set n to item i of picked
		set progress completed steps to (i - 1)
		set progress additional description to "(" & i & "/" & total & ") " & n
		set report to report & my uninstallOne(n, purge) & return
	end repeat
	set progress completed steps to total
	my refreshLaunchServices()
	display alert "卸载完成" message report as informational
end doUninstall

-- ========== 核心：建立/启动副本 ==========

on processAll(names, isNew)
	set total to count of names
	set progress total steps to total * 4
	set progress description to "正在准备微信副本…"
	set step to 0
	set failed to {}

	repeat with i from 1 to total
		set n to item i of names
		set tag to "(" & i & "/" & total & ") " & n
		set appPath to "/Applications/" & n & ".app"
		set binPath to appPath & "/" & binRel

		if not (my nameOk(n)) then
			set failed to failed & (n & "：名字不合法")
			set step to step + 4
			set progress completed steps to step
		else if my isRunning(binPath) then
			set progress additional description to tag & " 已在运行，激活窗口"
			my activateApp(appPath)
			set step to step + 4
			set progress completed steps to step
		else
			-- 1. 复制
			set progress additional description to tag & " 复制副本(1.4G)…"
			if not (my pathExists(appPath)) then
				try
					do shell script "/bin/cp -Rp " & quoted form of baseApp & " " & quoted form of appPath
				on error errMsg
					set failed to failed & (n & "：复制失败 " & errMsg)
					set step to step + 4
					set progress completed steps to step
					set progress additional description to ""
				end try
			end if
			set step to step + 1
			set progress completed steps to step

			if my pathExists(binPath) then
				-- 2. 改 bundle id
				set wantId to my idForName(n)
				set progress additional description to tag & " 设置标识 " & wantId & "…"
				set curId to my currentId(appPath)
				if curId is baseId or curId is "" then
					try
						do shell script "/usr/libexec/PlistBuddy -c " & quoted form of ("Set :CFBundleIdentifier " & wantId) & " " & quoted form of (appPath & "/Contents/Info.plist")
					on error errMsg
						set failed to failed & (n & "：改标识失败 " & errMsg)
					end try
					set step to step + 1
					set progress completed steps to step

					-- 3. 重签名
					set progress additional description to tag & " 重新签名（约 3 秒）…"
					try
						do shell script "/usr/bin/codesign --force --deep --sign - " & quoted form of appPath
					on error errMsg
						set failed to failed & (n & "：签名失败 " & errMsg)
					end try
					my registerApp(appPath)
				else
					set step to step + 1
					set progress completed steps to step
				end if
				set step to step + 1
				set progress completed steps to step

				-- 校验签名后的真实 id，不一致点 Dock 会跳到原版
				set realId to my signedId(appPath)
				if realId is not wantId then
					set failed to failed & (n & "：签名标识是 " & realId & "，应为 " & wantId)
				end if

				-- 4. 启动并等它真的起来
				set progress additional description to tag & " 启动中，等待微信响应…"
				do shell script "/usr/bin/nohup " & quoted form of binPath & " >/dev/null 2>&1 &"
				set ok to false
				repeat with w from 1 to 20
					delay 1
					set progress additional description to tag & " 启动中… " & w & "s"
					if my isRunning(binPath) then
						set ok to true
						exit repeat
					end if
				end repeat
				if not ok then set failed to failed & (n & "：启动后进程未存活")
				set step to step + 1
				set progress completed steps to step
			else
				set failed to failed & (n & "：" & binRel & " 不存在，不像是微信 app")
				set step to step + 3
				set progress completed steps to step
			end if
		end if
	end repeat

	set progress completed steps to (total * 4)
	set progress additional description to ""

	if (count of failed) > 0 then
		display alert "部分未完成" message my joinList(failed, return) as critical
	end if
end processAll

on uninstallOne(n, purge)
	set appPath to "/Applications/" & n & ".app"
	if appPath is baseApp then return n & "：原版微信，拒绝卸载"
	if not (my pathExists(appPath)) then return n & "：不存在，跳过"
	if my isRunning(appPath & "/" & binRel) then return n & "：正在运行，请先退出"

	set trashDir to (POSIX path of (path to trash folder))
	set stamp to do shell script "/bin/date +%H.%M.%S"
	set dest to trashDir & n & ".app"
	if my pathExists(dest) then set dest to trashDir & n & " " & stamp & ".app"
	try
		do shell script "/bin/mv " & quoted form of appPath & " " & quoted form of dest
	on error errMsg
		return n & "：移动失败 " & errMsg
	end try

	set dataDir to (POSIX path of (path to home folder)) & "Library/Containers/" & my idForName(n)
	set msg to n & "：app 已移入废纸篓"
	if my pathExists(dataDir) then
		if purge then
			set ddest to trashDir & my idForName(n)
			if my pathExists(ddest) then set ddest to ddest & "." & stamp
			try
				do shell script "/bin/mv " & quoted form of dataDir & " " & quoted form of ddest
				set msg to msg & "，数据目录也已移入"
			on error
				set msg to msg & "，但数据目录移动失败"
			end try
		else
			set msg to msg & "，数据目录保留"
		end if
	end if
	return msg
end uninstallOne

-- ========== 工具函数 ==========

on idForName(n)
	-- WeChat<数字> -> com.tencent.xinWeChat<数字>；其他 -> com.tencent.xinWeChat.<名字>
	-- 规则必须与 ~/Library/Containers 下已有数据目录一致，否则接不上已登录的账号
	if n starts with "WeChat" and (length of n) > 6 then
		set suffix to text 7 thru -1 of n
		if my isDigits(suffix) then return baseId & suffix
	end if
	return baseId & "." & n
end idForName

on isDigits(s)
	if s is "" then return false
	repeat with c in characters of s
		if "0123456789" does not contain (c as text) then return false
	end repeat
	return true
end isDigits

on nextFreeName()
	-- 找第一个没被占用的 WeChatN 作为默认名（从 2 开始，1 是原版）
	repeat with i from 2 to 20
		set candidate to "WeChat" & i
		if not (my pathExists("/Applications/" & candidate & ".app")) then return candidate
	end repeat
	return "WeChat2"
end nextFreeName

on nameOk(n)
	if n is "" then return false
	if n contains "/" then return false
	if n starts with "." then return false
	if ("/Applications/" & n & ".app") is baseApp then return false
	return true
end nameOk

on listCopies()
	-- 含 Contents/MacOS/WeChat 的才算微信副本，排除原版和同名的其他 app
	set cmd to "for a in /Applications/*.app; do [ \"$a\" = " & quoted form of baseApp & " ] && continue; [ -x \"$a/" & binRel & "\" ] || continue; b=$(basename \"$a\"); echo \"${b%.app}\"; done"
	try
		set out to do shell script cmd
	on error
		return {}
	end try
	return my splitLines(out)
end listCopies

on currentId(appPath)
	try
		return do shell script "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " & quoted form of (appPath & "/Contents/Info.plist")
	on error
		return ""
	end try
end currentId

on signedId(appPath)
	try
		return do shell script "/usr/bin/codesign -dv " & quoted form of appPath & " 2>&1 | /usr/bin/sed -n 's/^Identifier=//p'"
	on error
		return ""
	end try
end signedId

on isRunning(binPath)
	try
		do shell script "/usr/bin/pgrep -f " & quoted form of ("^" & binPath & "$")
		return true
	on error
		return false
	end try
end isRunning

on activateApp(appPath)
	try
		do shell script "/usr/bin/open -a " & quoted form of appPath
	end try
end activateApp

on registerApp(appPath)
	-- 刷新 LaunchServices，否则 Dock/启动台可能按旧 id 路由到原版窗口
	try
		do shell script "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f " & quoted form of appPath
	end try
end registerApp

on refreshLaunchServices()
	try
		do shell script "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user"
	end try
end refreshLaunchServices

on pathExists(p)
	try
		do shell script "/bin/test -e " & quoted form of p
		return true
	on error
		return false
	end try
end pathExists

on appsWritable()
	try
		do shell script "/bin/test -w /Applications"
		return true
	on error
		return false
	end try
end appsWritable

on chooseOne(t, p, opts)
	set r to choose from list opts with title t with prompt p default items {item 1 of opts}
	if r is false then return ""
	return item 1 of r
end chooseOne

on chooseMany(t, p, opts)
	set r to choose from list opts with title t with prompt p with multiple selections allowed
	if r is false then return {}
	return r
end chooseMany

on splitLines(s)
	-- do shell script 返回的行分隔符是 CR（return），不是 LF，按 LF 切会切不开
	set out to {}
	set tid to AppleScript's text item delimiters
	set AppleScript's text item delimiters to return
	set parts to text items of s
	set AppleScript's text item delimiters to tid
	repeat with x in parts
		set v to x as text
		if v is not "" then set end of out to v
	end repeat
	return out
end splitLines

on splitWords(s)
	set out to {}
	set tid to AppleScript's text item delimiters
	set AppleScript's text item delimiters to " "
	repeat with x in (text items of s)
		set v to x as text
		if v is not "" then set end of out to v
	end repeat
	set AppleScript's text item delimiters to tid
	return out
end splitWords

on joinList(lst, sep)
	set tid to AppleScript's text item delimiters
	set AppleScript's text item delimiters to sep
	set out to lst as text
	set AppleScript's text item delimiters to tid
	return out
end joinList
