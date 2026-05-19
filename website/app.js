// =============================================================================
// BURN — Web3 dapp module
//
// 把网页对接到 Base 主网的 BurnGame / BurnGameHook / BurnToken。
// 部署完合约后，把下面 CONFIG 里 0x0…0 的三个地址换成实际地址即可。
// =============================================================================

import {
  BrowserProvider,
  JsonRpcProvider,
  Contract,
  formatEther,
  parseEther,
  getAddress,
  ZeroAddress,
} from 'https://esm.sh/ethers@6.13.4';

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 1. CONFIG                                                                │
// ╰─────────────────────────────────────────────────────────────────────────╯
export const CONFIG = {
  CHAIN_ID: 8453,
  CHAIN_HEX: '0x2105',
  CHAIN_NAME: 'Base',
  // mainnet.base.org 默认严重限流，换公共节点。前端有 fallback 列表
  RPC_URL: 'https://base-rpc.publicnode.com',
  RPC_FALLBACKS: [
    'https://base.drpc.org',
    'https://mainnet.base.org',
    'https://base.gateway.tenderly.co',
  ],
  EXPLORER: 'https://basescan.org',

  // Base mainnet deployed 2026-05-20
  BURN_TOKEN: '0x215c7B9A00403B2a89A766F5D36E1178Dda22895',
  BURN_GAME:  '0xb1DB810363de384679aAc6b05C23fefAe43823D1',
  BURN_HOOK:  '0xBB5F858d2bB1abeEa1adf4103DEcEbC2321d0044',

  // 每次 burn 固定数量（跟合约常量一致：500,000 * 1e18）
  BURN_AMOUNT_WEI: 500_000n * 10n ** 18n,
  DEAD_ADDRESS: '0x000000000000000000000000000000000000dEaD',

  POLL_MS: 8000,
};

export const isConfigured = () =>
  CONFIG.BURN_GAME !== ZeroAddress &&
  CONFIG.BURN_TOKEN !== ZeroAddress &&
  CONFIG.BURN_HOOK !== ZeroAddress;

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 2. ABIs (只列前端要用到的函数 / 事件)                                    │
// ╰─────────────────────────────────────────────────────────────────────────╯
const BURN_TOKEN_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
];

const BURN_GAME_ABI = [
  'function currentLeader() view returns (address)',
  'function endTime() view returns (uint256)',
  'function roundId() view returns (uint256)',
  'function prizePool() view returns (uint256)',
  'function pendingWithdrawals(address) view returns (uint256)',
  'function totalPending() view returns (uint256)',
  'function timeLeft() view returns (uint256)',
  'function BURN_AMOUNT() view returns (uint256)',
  'function ROUND_DURATION() view returns (uint256)',
  'function burn()',
  'function settle()',
  'function withdrawPrize() returns (uint256)',
  'event Burned(uint256 indexed roundId, address indexed burner, uint256 newEndTime)',
  'event RoundEnded(uint256 indexed roundId, address indexed winner, uint256 prizeCredited)',
  'event Withdrawn(address indexed user, uint256 amount)',
];

const BURN_HOOK_ABI = ['function flush()'];

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 3. State                                                                 │
// ╰─────────────────────────────────────────────────────────────────────────╯
// 用一个 provider，失败时自动切到 fallback
function makeReadProvider(url) {
  return new JsonRpcProvider(url, undefined, { staticNetwork: true });
}

const state = {
  readProvider: makeReadProvider(CONFIG.RPC_URL),
  rpcIndex: 0,
  writeProvider: null, // BrowserProvider after wallet connect
  signer: null,
  account: null,
  chainId: null,
  blockNumber: 0,

  // Contract reads (live)
  prizePool: 0n,
  leader: ZeroAddress,
  endTime: 0n,
  roundId: 0n,
  totalDead: 0n,

  // Per-user
  userBurnBalance: 0n,
  userAllowance: 0n,
  userPending: 0n,
};

const subscribers = new Set();
const subscribe = (fn) => { subscribers.add(fn); return () => subscribers.delete(fn); };
const emit = () => subscribers.forEach((fn) => { try { fn(state); } catch (e) { console.error(e); } });

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 4. Wallet connection                                                     │
// ╰─────────────────────────────────────────────────────────────────────────╯

/** 已知钱包注入点 (在不同浏览器扩展 / 内嵌钱包下 EIP-1193 provider 的访问路径) */
const WALLET_RESOLVERS = {
  metamask: () => {
    if (window.ethereum?.providers?.length) {
      return window.ethereum.providers.find((p) => p.isMetaMask) || null;
    }
    return window.ethereum?.isMetaMask ? window.ethereum : null;
  },
  okx: () => window.okxwallet || null,
  binance: () => window.BinanceChain || window.binancew3w?.ethereum || null,
  tokenpocket: () => window.tokenpocket?.ethereum || (window.ethereum?.isTokenPocket ? window.ethereum : null),
};

const WALLET_DOWNLOAD = {
  metamask: 'https://metamask.io/download/',
  okx: 'https://www.okx.com/web3',
  binance: 'https://www.binance.com/en/web3wallet',
  tokenpocket: 'https://www.tokenpocket.pro/en/download/app',
};

export async function connectWallet(walletKey) {
  const provider = WALLET_RESOLVERS[walletKey]?.();
  if (!provider) {
    toast(`${walletKey} not detected. Opening download page…`, 'warn');
    window.open(WALLET_DOWNLOAD[walletKey], '_blank');
    return false;
  }

  try {
    const accounts = await provider.request({ method: 'eth_requestAccounts' });
    if (!accounts?.length) throw new Error('No account selected');

    state.writeProvider = new BrowserProvider(provider, 'any');
    state.signer = await state.writeProvider.getSigner();
    state.account = getAddress(accounts[0]);

    // chain check
    const net = await state.writeProvider.getNetwork();
    state.chainId = Number(net.chainId);
    if (state.chainId !== CONFIG.CHAIN_ID) {
      await ensureBaseChain(provider);
    }

    // chain / account change listeners
    provider.on?.('accountsChanged', (accs) => {
      state.account = accs?.[0] ? getAddress(accs[0]) : null;
      pullUserReads();
      emit();
    });
    provider.on?.('chainChanged', () => window.location.reload());

    localStorage.setItem('burn:lastWallet', walletKey);
    toast(`Connected ${shortAddr(state.account)}`, 'ok');
    await pullUserReads();
    emit();
    return true;
  } catch (e) {
    console.error(e);
    toast(`Connect failed: ${e?.shortMessage || e?.message || e}`, 'err');
    return false;
  }
}

async function ensureBaseChain(provider) {
  try {
    await provider.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: CONFIG.CHAIN_HEX }],
    });
  } catch (e) {
    if (e?.code === 4902) {
      await provider.request({
        method: 'wallet_addEthereumChain',
        params: [{
          chainId: CONFIG.CHAIN_HEX,
          chainName: CONFIG.CHAIN_NAME,
          nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: [CONFIG.RPC_URL],
          blockExplorerUrls: [CONFIG.EXPLORER],
        }],
      });
    } else throw e;
  }
}

export function disconnectWallet() {
  state.writeProvider = null;
  state.signer = null;
  state.account = null;
  state.userBurnBalance = 0n;
  state.userAllowance = 0n;
  state.userPending = 0n;
  localStorage.removeItem('burn:lastWallet');
  toast('Disconnected', 'ok');
  emit();
}

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 5. Reads (read-only via JsonRpcProvider, even without wallet)            │
// ╰─────────────────────────────────────────────────────────────────────────╯
function getReadGame()  { return new Contract(CONFIG.BURN_GAME,  BURN_GAME_ABI,  state.readProvider); }
function getReadToken() { return new Contract(CONFIG.BURN_TOKEN, BURN_TOKEN_ABI, state.readProvider); }

function rotateRpc() {
  const all = [CONFIG.RPC_URL, ...(CONFIG.RPC_FALLBACKS || [])];
  state.rpcIndex = (state.rpcIndex + 1) % all.length;
  const next = all[state.rpcIndex];
  console.warn('RPC rotation → ' + next);
  state.readProvider = makeReadProvider(next);
}

async function pullPublicReads() {
  if (!isConfigured()) return;
  try {
    const [game, token] = [getReadGame(), getReadToken()];
    const [pp, ld, et, rid, dead, bn] = await Promise.all([
      game.prizePool(),
      game.currentLeader(),
      game.endTime(),
      game.roundId(),
      token.balanceOf(CONFIG.DEAD_ADDRESS),
      state.readProvider.getBlockNumber(),
    ]);
    state.prizePool = pp;
    state.leader = ld;
    state.endTime = et;
    state.roundId = rid;
    state.totalDead = dead;
    state.blockNumber = bn;
  } catch (e) {
    console.warn('public reads failed:', e?.message || e);
    rotateRpc();
  }
}

async function pullUserReads() {
  if (!isConfigured() || !state.account) return;
  try {
    const [game, token] = [getReadGame(), getReadToken()];
    const [bal, allw, pend] = await Promise.all([
      token.balanceOf(state.account),
      token.allowance(state.account, CONFIG.BURN_GAME),
      game.pendingWithdrawals(state.account),
    ]);
    state.userBurnBalance = bal;
    state.userAllowance = allw;
    state.userPending = pend;
  } catch (e) {
    console.warn('user reads failed:', e?.message || e);
    rotateRpc();
  }
}

let pollHandle = null;
export function startPolling() {
  const cycle = async () => {
    await pullPublicReads();
    await pullUserReads();
    emit();
  };
  cycle();
  pollHandle = setInterval(cycle, CONFIG.POLL_MS);
}
export function stopPolling() { clearInterval(pollHandle); pollHandle = null; }

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 6. Writes                                                                │
// ╰─────────────────────────────────────────────────────────────────────────╯
function getWriteGame()  { return new Contract(CONFIG.BURN_GAME,  BURN_GAME_ABI,  state.signer); }
function getWriteToken() { return new Contract(CONFIG.BURN_TOKEN, BURN_TOKEN_ABI, state.signer); }
function getWriteHook()  { return new Contract(CONFIG.BURN_HOOK,  BURN_HOOK_ABI,  state.signer); }

async function requireConnected() {
  if (!state.signer) throw new Error('Connect a wallet first');
  if (!isConfigured()) throw new Error('Contracts not yet deployed');
  if (state.chainId !== CONFIG.CHAIN_ID) {
    await ensureBaseChain(state.writeProvider.provider);
  }
}

export async function doBurn() {
  try {
    await requireConnected();
    if (state.userBurnBalance < CONFIG.BURN_AMOUNT_WEI) {
      toast(`Need ${formatEther(CONFIG.BURN_AMOUNT_WEI)} BURN, you have ${formatEther(state.userBurnBalance)}`, 'err');
      return;
    }

    if (state.userAllowance < CONFIG.BURN_AMOUNT_WEI) {
      toast('Step 1/2: Approve 500,000 BURN…', 'info');
      const token = getWriteToken();
      const tx = await token.approve(CONFIG.BURN_GAME, CONFIG.BURN_AMOUNT_WEI);
      await tx.wait();
      state.userAllowance = CONFIG.BURN_AMOUNT_WEI;
    }

    toast('Step 2/2: burn() — sending 500,000 BURN to 0xdEaD…', 'info');
    const game = getWriteGame();
    const tx = await game.burn();
    const rcpt = await tx.wait();
    toast(`Burned. You're the leader. tx ${shortHash(rcpt.hash)}`, 'ok');
    await pullPublicReads(); await pullUserReads(); emit();
  } catch (e) {
    console.error(e);
    toast(`Burn failed: ${e?.shortMessage || e?.reason || e?.message || e}`, 'err');
  }
}

export async function doSettle() {
  try {
    await requireConnected();
    toast('settle() — finalizing the round…', 'info');
    const tx = await getWriteGame().settle();
    const rcpt = await tx.wait();
    toast(`Round settled. tx ${shortHash(rcpt.hash)}`, 'ok');
    await pullPublicReads(); await pullUserReads(); emit();
  } catch (e) {
    toast(`Settle failed: ${e?.shortMessage || e?.reason || e?.message || e}`, 'err');
  }
}

export async function doWithdrawPrize() {
  try {
    await requireConnected();
    if (state.userPending === 0n) { toast('Nothing to withdraw', 'warn'); return; }
    toast(`withdrawPrize() — pulling ${formatEther(state.userPending)} ETH…`, 'info');
    const tx = await getWriteGame().withdrawPrize();
    const rcpt = await tx.wait();
    toast(`Withdrew. tx ${shortHash(rcpt.hash)}`, 'ok');
    await pullUserReads(); emit();
  } catch (e) {
    toast(`Withdraw failed: ${e?.shortMessage || e?.reason || e?.message || e}`, 'err');
  }
}

export async function doFlush() {
  try {
    await requireConnected();
    toast('flush() — sweeping hook residuals…', 'info');
    const tx = await getWriteHook().flush();
    const rcpt = await tx.wait();
    toast(`Flushed. tx ${shortHash(rcpt.hash)}`, 'ok');
    await pullPublicReads(); emit();
  } catch (e) {
    toast(`Flush failed: ${e?.shortMessage || e?.reason || e?.message || e}`, 'err');
  }
}

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 7. Tiny UI helpers                                                       │
// ╰─────────────────────────────────────────────────────────────────────────╯
export const shortAddr = (a) => a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—';
export const shortHash = (h) => h ? `${h.slice(0, 6)}…${h.slice(-4)}` : '—';
export const fmtEth = (wei, dp = 4) => {
  if (typeof wei !== 'bigint') wei = BigInt(wei || 0);
  const s = formatEther(wei);
  const [i, d = ''] = s.split('.');
  return d ? `${i}.${d.slice(0, dp).padEnd(dp, '0')}` : `${i}.${'0'.repeat(dp)}`;
};
export const fmtBigNumber = (wei, decimals = 18) => {
  if (typeof wei !== 'bigint') wei = BigInt(wei || 0);
  const whole = wei / (10n ** BigInt(decimals));
  if (whole >= 1_000_000_000n) return (Number(whole) / 1e9).toFixed(2) + 'B';
  if (whole >= 1_000_000n) return (Number(whole) / 1e6).toFixed(2) + 'M';
  if (whole >= 1_000n) return (Number(whole) / 1e3).toFixed(2) + 'K';
  return whole.toString();
};

export function toast(msg, kind = 'info') {
  const stack = document.getElementById('toast-stack');
  if (!stack) return;
  const el = document.createElement('div');
  el.className = `toast toast-${kind}`;
  el.textContent = msg;
  stack.appendChild(el);
  setTimeout(() => el.classList.add('toast-show'), 16);
  setTimeout(() => {
    el.classList.remove('toast-show');
    setTimeout(() => el.remove(), 300);
  }, kind === 'err' ? 6000 : 3800);
}

// ╭─────────────────────────────────────────────────────────────────────────╮
// │ 8. Auto-init + DOM binding                                               │
// ╰─────────────────────────────────────────────────────────────────────────╯
export { state, subscribe };

window.BURN = {
  CONFIG, state, subscribe, isConfigured,
  connectWallet, disconnectWallet,
  doBurn, doSettle, doWithdrawPrize, doFlush,
  startPolling, stopPolling,
  shortAddr, shortHash, fmtEth, fmtBigNumber, toast,
};
