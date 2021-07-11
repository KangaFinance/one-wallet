import 'dotenv/config'
import baseConfig from '../../lib/config/common'
import { merge } from 'lodash'
const config = merge({}, baseConfig, {
  defaultStorePath: process.env.DEFAULT_STORE_PATH || 'wallets',
  defaults: {
  },
  debug: process.env.DEBUG,
})
export default config