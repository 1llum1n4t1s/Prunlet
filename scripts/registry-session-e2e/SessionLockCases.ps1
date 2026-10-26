function TestCliLock {
 $leaf='lock-cli';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
 $lock=[IO.File]::Open((Join-Path $recovery 'maintenance.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$p=$null
 try{
  $p=Child @('registry-delete','--view','64','--value-name=binary','--',$f.path);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Close();$sw=[Diagnostics.Stopwatch]::StartNew()
  Write-Host 'CLI native session waiting on owned maintenance lock for 65 seconds.'
  while($sw.Elapsed.TotalSeconds-lt 65){Assert (!$p.HasExited) 'CLI exited before lock release';Start-Sleep -Milliseconds 200}
  Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'CLI changed source while shared lock unavailable'
  $held=$sw.Elapsed.TotalSeconds;$lock.Dispose();$lock=$null
  Assert ($p.WaitForExit(30000)) 'CLI did not continue after lock release';$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$data=$stdout|ConvertFrom-Json -AsHashtable -Depth 50
  Assert ($p.ExitCode-eq 0-and$data.operationId-and$data.items[0].kind-eq'registry-value') 'CLI lock-wait final result';Assert ($stderr-match'Waiting for recovery lock'-and$stderr-match'Recovery lock acquired') 'CLI lock progress/acquired missing'
  $r=InvokePrunletCli @('restore',$data.operationId);Assert ($r.exitCode-eq 0) 'CLI lock roundtrip restore';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'CLI lock roundtrip raw/security mismatch'
  return @{heldSeconds=$held;exitCode=$p.ExitCode;stdout=$stdout;stderr=$stderr;operationId=$data.operationId;restore=$r;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }finally{if($lock){$lock.Dispose()};if($p){if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}}
}
function TestMcpLock {
 $leaf='lock-mcp';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf};$p=McpStart;$lock=$null;$frames=[Collections.Generic.List[object]]::new()
 try{
  $lock=[IO.File]::Open((Join-Path $recovery 'maintenance.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  $script:RpcId++;$id=$script:RpcId;$token='session-lock-'+[guid]::NewGuid().ToString('N')
  $request=@{jsonrpc='2.0';id=$id;method='tools/call';params=@{name='delete_registry';arguments=@{path=$f.path;view='64';valueName='binary'};'_meta'=@{progressToken=$token}}}
  $p.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 30 -Compress));$p.StandardInput.Flush();$read=$p.StandardOutput.ReadLineAsync();$sw=[Diagnostics.Stopwatch]::StartNew()
  Write-Host 'MCP native session waiting on owned maintenance lock for 65 seconds.'
  while($sw.Elapsed.TotalSeconds-lt 65){
   Assert (!$p.HasExited) 'MCP process exited while lock held'
   if($read.IsCompleted){$line=$read.GetAwaiter().GetResult();Assert ($null-ne$line) 'MCP output closed while lock held';$frame=$line|ConvertFrom-Json -AsHashtable -Depth 50;Assert ($frame.id-ne$id) 'MCP returned before lock release';$frames.Add($frame);$read=$p.StandardOutput.ReadLineAsync()}
   Start-Sleep -Milliseconds 100
  }
  Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'MCP changed source before lock release';$held=$sw.Elapsed.TotalSeconds;$lock.Dispose();$lock=$null
  $reply=$null
  for($i=0;$i-lt 256;$i++){Assert ($read.Wait(30000)) 'MCP did not continue after lock release';$line=$read.GetAwaiter().GetResult();Assert ($null-ne$line) 'MCP output closed';$frame=$line|ConvertFrom-Json -AsHashtable -Depth 50;$frames.Add($frame);if($frame.id-eq$id){$reply=$frame;break};$read=$p.StandardOutput.ReadLineAsync()}
  Assert ($reply-and!$reply.result.isError) 'MCP lock-wait final result';$data=McpData $reply;Assert ($data.operationId-and$data.items[0].kind-eq'registry-value') 'MCP lock final kind/id'
  $notifications=@($frames|Where-Object {$_.method-eq'notifications/progress'});Assert ($notifications.Count-gt 2) 'MCP wait progress absent';foreach($n in $notifications){Assert ($n.params.progressToken-ceq$token) 'MCP progress token mismatch'}
  Assert (@($notifications|Where-Object {$_.params.message-match'Recovery lock acquired'}).Count-eq 1) 'MCP acquisition notification missing/duplicated'
  $script:RpcId++;$restoreId=$script:RpcId;$restoreRequest=@{jsonrpc='2.0';id=$restoreId;method='tools/call';params=@{name='restore_registry';arguments=@{operationId=$data.operationId}}}
  $p.StandardInput.WriteLine(($restoreRequest|ConvertTo-Json -Depth 20 -Compress));$p.StandardInput.Flush();$r=$null;$afterFinal=[Collections.Generic.List[object]]::new()
  for($i=0;$i-lt 128;$i++){$next=$p.StandardOutput.ReadLineAsync();Assert ($next.Wait(30000)) 'MCP restore response timeout';$line=$next.GetAwaiter().GetResult();Assert ($null-ne$line) 'MCP restore output closed';$frame=$line|ConvertFrom-Json -AsHashtable -Depth 50;$afterFinal.Add($frame);Assert (!($frame.method-eq'notifications/progress'-and$frame.params.progressToken-ceq$token)) 'Progress emitted after original final response';if($frame.id-eq$restoreId){$r=$frame;break}}
  Assert ($r-and!$r.result.isError) 'MCP lock restore failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'MCP lock roundtrip raw/security mismatch'
  $p.StandardInput.Close();$tailTask=$p.StandardOutput.ReadToEndAsync();Assert ($p.WaitForExit(15000)) 'MCP shutdown timeout';$tail=$tailTask.GetAwaiter().GetResult();Assert ([string]::IsNullOrWhiteSpace($tail)) 'MCP emitted output after final completed response';Assert ($p.ExitCode-eq 0) 'MCP shutdown exit'
  return @{heldSeconds=$held;exitCode=$p.ExitCode;operationId=$data.operationId;token=$token;frames=@($frames);restore=$r;afterFinalFrames=@($afterFinal);afterFinalOutput=$tail;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }finally{if($lock){$lock.Dispose()};if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
function TestDisconnectedClient {
 $leaf='disconnected-client';$f=NativeRequest 'create' @{leaf=$leaf};$before=NativeRequest 'observe' @{leaf=$leaf}
 $existing=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($dir in (RegistryOperationDirectories $recovery)){$null=$existing.Add($dir)}
 $lock=[IO.File]::Open((Join-Path $recovery 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$p=$null
 try{
  $p=Child @('registry-delete','--view','64','--value-name=binary','--',$f.path);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Close()
  Start-Sleep -Seconds 3;Assert (!$p.HasExited) 'Disconnect client exited before lock wait';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Disconnect source changed before lock release'
  $clientPid=$p.Id;$p.Kill($false);$p.WaitForExit();$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();Assert ($stderr-match'Waiting for recovery lock') 'Client was not in accepted Core lock wait before disconnect'
  Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Disconnect changed source before lock release';$lock.Dispose();$lock=$null
  $sw=[Diagnostics.Stopwatch]::StartNew();$new=@();$opRoot=$null
  while($sw.Elapsed.TotalSeconds-lt 30){
   $new=@((RegistryOperationDirectories $recovery)|Where-Object {!$existing.Contains($_)})
   if($new.Count-eq 1-and[IO.File]::Exists((Join-Path $new[0] 'registry-delete-complete.json'))){$observed=NativeRequest 'observe' @{leaf=$leaf};if(!$observed.values.ContainsKey('binary')){$opRoot=$new[0];break}}
   Start-Sleep -Milliseconds 150
  }
  Assert ($opRoot-and$new.Count-eq 1) 'Disconnected request did not complete exactly one recoverable Core operation'
  $manifest=ReadJson (Join-Path $opRoot 'registry-manifest.json');$id=$manifest.operationId;Assert ($manifest.path-ceq$f.path-and$manifest.valueName-ceq'binary') 'Recovered operation does not identify the disconnected fixture'
  $digests=@{};foreach($file in [IO.Directory]::EnumerateFiles($opRoot,'*.json')){$digests[[IO.Path]::GetFileName($file)]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
  $deleted=NativeRequest 'observe' @{leaf=$leaf};$rec=InvokePrunletCli @('registry-reconcile',$id);Assert ($rec.exitCode-eq 0-and$rec.json.items[0].status-eq'deleted'-and$rec.json.items[0].kind-eq'registry-value') 'Disconnected committed operation reconcile result'
  Assert (Same $deleted (NativeRequest 'observe' @{leaf=$leaf})) 'Reconcile changed the registry'
  Assert (@([IO.Directory]::EnumerateFiles($opRoot,'*.json')).Count-eq$digests.Count) 'Reconcile created metadata';foreach($file in [IO.Directory]::EnumerateFiles($opRoot,'*.json')){Assert ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash-ceq$digests[[IO.Path]::GetFileName($file)]) 'Reconcile modified metadata'}
  $r=InvokePrunletCli @('restore',$id);Assert ($r.exitCode-eq 0) 'Disconnected operation restore failed';Assert (Same $before (NativeRequest 'observe' @{leaf=$leaf})) 'Disconnected restore raw/class/full-security mismatch'
  return @{clientPid=$clientPid;clientTerminatedDuringLockWait=$true;clientStdout=$stdout;clientStderr=$stderr;operationIdFromPersistedManifest=$id;operationCount=$new.Count;deleteWasNotRepeated=$true;serverCompletedBeforeStop=$true;reconcile=$rec;reconcileMetadataUnchanged=$true;restore=$r;before=$before;after=(NativeRequest 'observe' @{leaf=$leaf})}
 }finally{if($lock){$lock.Dispose()};if($p){if(!$p.HasExited){$p.Kill($false);$p.WaitForExit()};$p.Dispose()}}
}
