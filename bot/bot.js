require('dotenv').config();
const { Telegraf } = require('telegraf');
const { ethers } = require('ethers');

const bot = new Telegraf(process.env.BOT_TOKEN);

const provider = new ethers.JsonRpcProvider('https://mainnet.base.org');
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS;
const ABI = require('./abi.json');
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

bot.start((ctx) => {
  ctx.reply(`
🏙️🐒 *Welcome to Ape City Launchpad on Base!*

Launch memecoins for FREE (only gas).
Bonding curve → Auto migration to Uniswap V3.
Creator reward + burned LP.

Use /launch to create your token!
  `, { parse_mode: 'Markdown' });
});

bot.command('launch', (ctx) => {
  ctx.reply('Reply with token details:\n\n`Name|Symbol|Supply`\nExample: `MyCoin|MYC|1000000000`', { parse_mode: 'Markdown' });
});

bot.on('text', async (ctx) => {
  const text = ctx.message.text.trim();
  if (!text.includes('|')) return;

  const [name, symbol, supplyStr] = text.split('|').map(s => s.trim());
  if (!name || !symbol || !supplyStr) {
    return ctx.reply('❌ Invalid format. Use: Name|Symbol|Supply');
  }

  try {
    const supply = ethers.parseUnits(supplyStr, 18);
    ctx.reply('🚀 Launching your token... (10-30 sec)');

    const tx = await contract.launchToken(name, symbol, supply);
    const receipt = await tx.wait();

    const tokenAddress = receipt.logs[0].address; // Token creation event

    ctx.reply(`
✅ *Token Launched Successfully!*

Name: ${name}
Symbol: ${symbol}
Supply: ${supplyStr}

🔗 Token Address: \`${tokenAddress}\`

Trading is live on bonding curve!
When ~4.2 ETH bought → auto-migrates to Uniswap V3 (burned LP).

Share and pump it! 🏙️🐒
    `, { parse_mode: 'Markdown' });
  } catch (error) {
    console.error(error);
    ctx.reply('❌ Launch failed. Check details or try again.');
  }
});

bot.launch();
console.log('Ape City Bot is running...');
