import React, { useState } from 'react'
import { useHistory, useRouteMatch } from 'react-router'
import { Layout, Image, Menu, Row, Tag } from 'antd'
import { PlusCircleOutlined, UnorderedListOutlined, HistoryOutlined } from '@ant-design/icons'
import HarmonyLogo from '../assets/harmony.svg'
import HarmonyIcon from '../assets/harmony-icon.svg'
import config from '../config'
import Paths from '../constants/paths'
import styled from 'styled-components'
import { useWindowDimensions } from '../util'

const Text = styled.p`
  color: #fafafa;
  text-align: center;
  a, a:hover {
    color: #fafafa;
  }
`
const SiderMenu = ({ ...args }) => {
  const { width } = useWindowDimensions()
  const history = useHistory()
  const [collapsed, setCollapsed] = useState()
  const match = useRouteMatch('/:action')
  const { action } = match ? match.params : {}
  const nav = ({ key }) => {
    history.push(Paths[key])
  }
  console.log(width)
  return (
    <Layout.Sider collapsible={width < 900} onCollapse={c => setCollapsed(c)} {...args}>
      {/* <Image src='/assets/harmony.svg' /> */}
      <Row justify='center'>
        <Image preview={false} src={collapsed ? HarmonyIcon : HarmonyLogo} style={{ cursor: 'pointer', padding: collapsed ? 16 : 32 }} onClick={() => history.push('/')} />
      </Row>
      {!collapsed && <Text><a href='https://docs.harmony.one/home/developers/wallets/1wallet' target='_blank'>{config.appName} {config.version}</a></Text>}
      {!collapsed && <Row justify='center' style={{ marginBottom: 10 }}><Tag color='#0094c0'>Beta</Tag></Row>}
      <Menu theme='dark' mode='inline' onClick={nav} selectedKeys={[action]}>
        <Menu.Item key='create' icon={<PlusCircleOutlined />}>Create</Menu.Item>
        <Menu.Item key='wallets' icon={<UnorderedListOutlined />}>Wallets</Menu.Item>
        <Menu.Item key='restore' icon={<HistoryOutlined />}>Restore</Menu.Item>
      </Menu>

    </Layout.Sider>
  )
}

export default SiderMenu
