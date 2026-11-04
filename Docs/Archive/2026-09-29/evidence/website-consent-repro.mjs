import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync('/Users/developer/Documents/code/louppe/website/analytics-consent.js','utf8');
const sharedStorage = new Map();
const key = 'louppe.analytics-consent.v1';
sharedStorage.set(key, JSON.stringify({value:'accepted',at:Date.now()}));

function page(name) {
  const handlers = new Map();
  const appended = [];
  const banner = {hidden:true};
  const settings = {focus(){},addEventListener(type,callback){handlers.set('settings:'+type,callback);}};
  const choices = ['rejected','accepted'].map(value=>({focus(){},getAttribute(){return value;},addEventListener(type,callback){handlers.set(value+':'+type,callback);}}));
  const document = {
    cookie:'',getElementById(){return banner;},querySelector(){return settings;},querySelectorAll(){return choices;},
    createElement(){return {};},head:{appendChild(script){appended.push(script.src);}},
    addEventListener(type,callback){handlers.set('document:'+type,callback);}
  };
  const location = {hostname:'louppe.eu',protocol:'https:',href:'https://louppe.eu/',reload(){handlers.set('reloaded',true);}};
  const context = {document,location,Date,JSON,Number,URL,localStorage:{getItem(k){return sharedStorage.get(k)||null;},setItem(k,v){sharedStorage.set(k,v);}}};
  context.window = context;
  context.addEventListener = (type,callback)=>handlers.set('window:'+type,callback);
  vm.runInNewContext(source,context,{filename:'analytics-consent.js'});
  return {name,context,handlers,appended};
}
const a = page('A');
const b = page('B');
assert.equal(a.appended.length,1);
assert.equal(b.appended.length,1);
b.handlers.get('rejected:click')();
assert.equal(JSON.parse(sharedStorage.get(key)).value,'rejected');
assert.equal(b.context['ga-disable-G-9P9KKLZ5BN'],true);
assert.equal(a.context['ga-disable-G-9P9KKLZ5BN'],false);
assert.equal(a.handlers.has('window:storage'),false);
assert.equal(a.handlers.has('document:visibilitychange'),false);
const count = a.context.dataLayer.length;
a.handlers.get('document:click')({target:{closest(){return {href:'https://github.com/alexander-markin-meow/louppe-media-culler/releases/latest/download/Louppe.zip'};}}});
assert.equal(a.context.dataLayer.length,count+1);
console.log(JSON.stringify({savedChoice:'rejected',tabBDisabled:true,tabADisabled:false,tabAQueuedDownloadAfterWithdrawal:true,storageListener:false,visibilityListener:false},null,2));
