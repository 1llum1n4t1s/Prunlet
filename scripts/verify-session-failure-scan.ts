import { accessSync, constants, lstatSync, mkdirSync, writeFileSync, utimesSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
const root = process.argv[2];
if (!root || !/^D:[\\/]/i.test(root)) throw new Error('Provide a new absolute external D fixture directory');
const destination = resolve(root);
for (const excluded of [resolve(import.meta.dir, '..'), join(homedir(), '.codex')]) {
  if (destination.toLowerCase() === excluded.toLowerCase() || destination.toLowerCase().startsWith(excluded.toLowerCase() + '\\')) throw new Error('Repository and Codex home are excluded');
}
for (let parent = dirname(destination); ; parent = dirname(parent)) {
  const stat = lstatSync(parent);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Existing ordinary parent directories required');
  if (dirname(parent) === parent) break;
}
accessSync(dirname(destination), constants.W_OK);
mkdirSync(root);
const dto = { dryRun: false, items: [{ path: 'D:\\fixture\\a.txt', status: 'ambiguous', error: 'Access denied {quoted}' }] };
const row = (type: string, payload: object, timestamp = '2026-11-07T00:00:00Z') => JSON.stringify({type, timestamp, payload});
const lines = [
  row('response_item', {type:'custom_tool_call', name:'exec', call_id:'a', input:'await tools.exec_command({cmd:"prunlet.exe delete"})'}),
  row('response_item', {type:'custom_tool_call_output', call_id:'a', output:[{type:'input_text',text:'Command output:\n'+JSON.stringify(dto,null,2)}]}),
  row('response_item', {type:'function_call', call_id:'b',name:'mcp__prunlet__delete_files',arguments:'{}'}),
  row('response_item', {type:'function_call_output', call_id:'b', output:JSON.stringify({content:[{text:JSON.stringify(dto)}],structuredContent:dto})}),
  row('response_item', {type:'function_call', call_id:'c',name:'mcp__prunlet__delete_files',arguments:'{}'}),
  row('response_item', {type:'function_call_output', call_id:'c', output:JSON.stringify({...dto,dryRun:true})}),
  row('response_item', {type:'function_call', call_id:'reordered',name:'mcp__prunlet__delete_files',arguments:'{}'}),
  row('response_item', {type:'function_call_output', call_id:'reordered', output:'Header:\n'+JSON.stringify({items:dto.items,dryRun:false},null,2)}),
  row('response_item', {type:'function_call', call_id:'other',name:'another_product',arguments:'{}'}),
  row('response_item', {type:'function_call_output',call_id:'other',output:JSON.stringify(dto)}),
  ...[JSON.stringify({exit_code:1}), JSON.stringify({exitCode:-1},null,2), {exit_code:2}, 'Process exited with code -1', JSON.stringify({exitCode:0})].flatMap((output,index) => [
    row('response_item', {type:'function_call',call_id:'exit'+index,name:'exec',arguments:'prunlet.exe delete'}),
    row('response_item', {type:'function_call_output',call_id:'exit'+index,output})
  ]),
  row('response_item', {type:'function_call_output', call_id:'d', output:JSON.stringify(dto)}, '2026-11-01T00:00:00Z'),
  row('response_item', {type:'message', role:'assistant',content:[{text:JSON.stringify(dto)}]}),
  row('event_msg', {type:'agent_message',message:JSON.stringify(dto)}),
  '{malformed'
];
writeFileSync(join(root,'fixture.jsonl'),lines.join('\n'));
utimesSync(join(root,'fixture.jsonl'),new Date('2010-01-01'),new Date('2010-01-01'));
const result=Bun.spawnSync([process.execPath,join(import.meta.dir,'scan-prunlet-failures.ts'),'--root',root,'--until','2026-11-07T01:00:00Z']);
if(result.exitCode!==0)throw new Error(result.stderr.toString());
const summary=JSON.parse(result.stdout.toString());
if(summary.failureObservations!==3||summary.distinctPathStatusErrors!==1||summary.malformedLines!==1||summary.byReason.access_denied!==3||summary.unattributedDtoItems!==1||summary.nonDtoFailedCalls!==4)throw new Error(JSON.stringify(summary));
console.log(JSON.stringify({passed:true, checks:['multiline DTO','nested wrappers','same-event deduplication','repeated observation','dry-run exclusion','timestamp exclusion','conversation exclusion','malformed line tolerance','event time independent of mtime']}));
