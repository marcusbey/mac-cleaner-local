const { packager } = require('@electron/packager');
const path = require('node:path');
(async()=>{
 const arch = process.argv[2] || 'arm64';
 if (!['arm64','x64'].includes(arch)) throw new Error('Expected arm64 or x64');
 const apps = await packager({dir:__dirname,out:path.resolve(__dirname,'../dist/electron'),name:'App Cleaner Desktop',platform:'darwin',arch,electronVersion:'45.2.1',appBundleId:'local.appcleaner.desktop',appVersion:'0.3.0',buildVersion:'3',appCategoryType:'public.app-category.utilities',darwinDarkModeSupport:true,asar:true,prune:true,overwrite:true,ignore:[/^\/package\.cjs$/,/^\/launcher\.test\.cjs$/,/^\/package-lock\.json$/],extraResource:[path.resolve(__dirname,'../dist/universal/App Cleaner Local.app')],extendInfo:{LSMinimumSystemVersion:'14.0'}});
 console.log(apps.join('\n'));
})().catch(error=>{console.error(error);process.exitCode=1;});
