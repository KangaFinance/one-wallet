import axios from 'axios'
import config from '../config'
import { isEqual } from 'lodash'

const apiConfig = {
  relayer: config.defaults.relayer,
  network: config.defaults.network,
  secret: ''
}

const headers = (secret, network) => ({
  headers: { 'X-ONEWALLET-RELAYER-SECRET': secret, 'X-NETWORK': network }
})

let api = axios.create({
  baseURL: config.defaults.relayer,
  headers: headers(apiConfig.secret, apiConfig.network),
  timeout: 10000,
})

export const initAPI = (store) => {
  console.log(store)
  store.subscribe(() => {
    const state = store.getState()
    const { relayer: relayerId, network, secret } = state.wallet
    let relayer = relayerId
    if (relayer && !relayer.startsWith('http')) {
      relayer = config.relayers[relayer]
      if (!relayer) {
        relayer = config.defaults.relayer
      }
    }
    if (!isEqual(apiConfig, { relayer, network, secret })) {
      api = axios.create({
        baseURL: relayer,
        headers: headers(secret, network),
        timeout: 10000,
      })
    }
    console.log('api update: ', { relayer, network, secret })
  })
}

export default {
  blockchain: {
    getWallet: async ({ provider, address }) => {
      throw new Error('Not implemented')
    },
    getBalance: async ({ provider, address }) => {
      throw new Error('Not implemented')
    }
  },
  relayer: {
    create: async ({ root, height, interval, t0, lifespan, slotSize, lastResortAddress, dailyLimit }) => {
      const { data } = await api.post('/new', { root, height, interval, t0, lifespan, slotSize, lastResortAddress, dailyLimit })
      return data
    },
    commit: async ({ address, hash }) => {
      const { data } = await api.post('/commit', { address, hash })
      return data
    },
    revealTransfer: async ({ neighbors, index, eotp, dest, amount, address }) => {
      const { data } = await api.post('/reveal/transfer', { neighbors, index, eotp, dest, amount, address })
      return data
    },
    revealRecovery: async ({ neighbors, index, eotp, address }) => {
      const { data } = await api.post('/reveal/recovery', { neighbors, index, eotp, address })
      return data
    },
    retire: async ({ address }) => {
      const { data } = await api.post('/retire', { address })
      return data
    },
    health: async () => {
      const { data } = await api.get('/health')
      return data === 'OK'
    }
  },
}
