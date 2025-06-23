import { useEffect, useState } from 'react'
import { Card, Result } from 'antd'
import { ethers } from 'ethers'

const pgtcrAbi = [
  {
    type: 'function',
    name: 'disputeIDToItemID',
    inputs: [{ type: 'uint256' }],
    outputs: [{ type: 'bytes32' }],
    stateMutability: 'view'
  },
  // {
  //   type: 'function',
  //   name: 'arbitratorDisputeIDToItemID',
  //   inputs: [{ type: 'address' },{ type: 'uint256' }],
  //   outputs: [{ type: 'bytes32' }],
  //   stateMutability: 'view'
  // },
]
export default function EvidenceDisplay () {
  const [href, setHref] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    ;(async () => {
      try {
        const raw = decodeURIComponent(window.location.search.slice(1))
        console.log(raw)
        if (!raw) throw new Error('Missing injected message')

        const msg = JSON.parse(raw)
        const {
          disputeID,
          arbitrableContractAddress,
          arbitrableJsonRpcUrl,
          arbitrableChainID
        } = msg

        if (!disputeID || !arbitrableContractAddress) {
          throw new Error('disputeID / contract addr missing')
        }

        const provider = new ethers.JsonRpcProvider(arbitrableJsonRpcUrl)
        const pgtcr = new ethers.Contract(
          arbitrableContractAddress,
          pgtcrAbi,
          provider
        )
        const itemID = await pgtcr.disputeIDToItemID(disputeID)
        // const itemID = await pgtcr.arbitratorDisputeIDToItemID("0x9C1dA9A04925bDfDedf0f6421bC7EEa8305F9002", disputeID)

        setHref(
          `https://curate.kleros.io/tcr/${arbitrableChainID}/${arbitrableContractAddress}/${itemID}`
        )
      } catch (e) {
        console.error(e)
        setError(e.message)
      }
    })()
  }, [])

  if (error) {
    return (
      <Card variant='outlined'>
        <Result status='warning' title={error} />
      </Card>
    )
  }

  if (!href) return <Card loading variant='outlined' />

  return (
    <Card variant='outlined'>
      <a href={href} target='_blank' rel='noopener noreferrer'>
        View Submission
      </a>
    </Card>
  )
}
